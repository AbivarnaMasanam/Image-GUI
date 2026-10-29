defmodule ImageProWeb.ImageProcessorLive do
  use ImageProWeb, :live_view

  @thumb_dir "priv/static/uploads/thumbnails"
  @processed_dir "priv/static/uploads/processed"
  @zip_dir "priv/static/uploads/zips"
  # originals are kept out of priv/static so they are not publicly served
  @original_dir "priv/uploads/originals"

  # --------------------------------------------------
  # Mount / render
  # --------------------------------------------------

  def mount(%{"operation" => operation}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, String.capitalize(operation) <> " Page")
      |> assign(:operation, operation)
      |> assign(:images, [])
      |> assign(:selected_image, nil)
      |> assign(:rotation, 90)
      |> assign(:quality, 80)
      |> assign(:step, :edit)
      |> assign(:results, [])
      |> assign(:zip_url, nil)
      |> allow_upload(:image,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 10,
        max_file_size: 10_000_000
      )

    {:ok, socket}
  end

  def render(%{step: :download} = assigns), do: ImageProWeb.PageHTML.downloadfile(assigns)
  def render(assigns), do: ImageProWeb.PageHTML.choosefile(assigns)

  # --------------------------------------------------
  # Upload -> editor
  # --------------------------------------------------

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("process_image", _params, socket) do
    images =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        # entry.ref is only unique inside one socket, so use a random id to
        # stop two users overwriting each other's files.
        id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

        # The temp upload file is deleted when this callback returns, so copy it.
        original_path = copy_original(path, id, entry.client_name)
        thumbnail_path = create_thumbnail(original_path, id)

        # consume_uploaded_entries requires {:ok, value} from the callback.
        {:ok,
         %{
           id: id,
           filename: entry.client_name,
           path: original_path,
           thumbnail_path: thumbnail_path,
           rotation: 0,
           inverted: false,
           quality: 100
         }}
      end)

    {:noreply, socket |> assign(:images, images) |> assign(:selected_image, nil)}
  end

  # --------------------------------------------------
  # Editor events
  # --------------------------------------------------

  def handle_event("select_image", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_image, id)}
  end

  # preset buttons (90 / 180 / 270)
  def handle_event("set_rotation", %{"rotation" => value}, socket) do
    {:noreply, assign(socket, :rotation, clamp(value, 1, 360, socket.assigns.rotation))}
  end

  # custom number box + slider (one form, phx-change)
  def handle_event("set_custom_rotation", %{"_target" => [field]} = params, socket) do
    {:noreply, assign(socket, :rotation, clamp(params[field], 1, 360, socket.assigns.rotation))}
  end

  # quality number box + slider (compress / convert)
  def handle_event("set_quality", %{"_target" => [field]} = params, socket) do
    {:noreply, assign(socket, :quality, clamp(params[field], 0, 100, socket.assigns.quality))}
  end

  def handle_event("apply_selected", _params, socket) do
    case socket.assigns.selected_image do
      nil -> {:noreply, socket}
      id -> {:noreply, apply_to(socket, [id])}
    end
  end

  def handle_event("apply_all", _params, socket) do
    ids = Enum.map(socket.assigns.images, & &1.id)
    {:noreply, apply_to(socket, ids)}
  end

  # --------------------------------------------------
  # Final processing -> download page
  # --------------------------------------------------

  def handle_event("process_final", _params, socket) do
    %{operation: operation, images: images} = socket.assigns

    File.mkdir_p!(@processed_dir)

    outcomes = Enum.map(images, &process_one(&1, operation))

    case Enum.find(outcomes, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not process images: #{inspect(reason)}")}

      nil ->
        results = outcomes |> Enum.map(fn {:ok, r} -> r end) |> dedupe_filenames()

        zip_url = if length(results) > 1, do: build_zip(results), else: nil

        {:noreply,
         socket
         |> assign(:results, results)
         |> assign(:zip_url, zip_url)
         |> assign(:step, :download)}
    end
  end

  # --------------------------------------------------
  # Helpers: applying settings
  # --------------------------------------------------

  defp apply_to(socket, ids) do
    %{operation: operation, rotation: rotation, quality: quality, images: images} = socket.assigns

    images =
      Enum.map(images, fn image ->
        if image.id in ids do
          case operation do
            "rotate" -> %{image | rotation: rotation}
            "invert" -> %{image | inverted: true}
            _compress_or_convert -> %{image | quality: quality}
          end
        else
          image
        end
      end)

    assign(socket, :images, images)
  end

  defp clamp(value, lo, hi, fallback) do
    case Integer.parse(to_string(value)) do
      {int, _rest} -> int |> max(lo) |> min(hi)
      :error -> fallback
    end
  end

  # --------------------------------------------------
  # Helpers: image processing (Vix / libvips)
  # --------------------------------------------------

  defp process_one(image, operation) do
    out_ext =
      if operation in ["compress", "convert"],
        do: ".jpg",
        else: image.filename |> Path.extname() |> String.downcase()

    out_path = Path.join(@processed_dir, image.id <> out_ext)

    with {:ok, vips} <- Vix.Vips.Image.new_from_file(image.path),
         {:ok, vips} <- transform(vips, operation, image),
         :ok <- Vix.Vips.Image.write_to_file(vips, save_target(out_path, operation, image)) do
      {:ok,
       %{
         id: image.id,
         filename: Path.rootname(image.filename) <> out_ext,
         path: out_path,
         url: "/uploads/processed/" <> image.id <> out_ext,
         thumbnail_path: create_thumbnail(out_path, image.id <> "-out"),
         size: File.stat!(out_path).size
       }}
    end
  end

  # No change needed
  defp transform(vips, "rotate", %{rotation: deg}) when rem(deg, 360) == 0, do: {:ok, vips}

  # 90 / 180 / 270: lossless, clockwise
  defp transform(vips, "rotate", %{rotation: 90}),
    do: Vix.Vips.Operation.rot(vips, :VIPS_ANGLE_D90)

  defp transform(vips, "rotate", %{rotation: 180}),
    do: Vix.Vips.Operation.rot(vips, :VIPS_ANGLE_D180)

  defp transform(vips, "rotate", %{rotation: 270}),
    do: Vix.Vips.Operation.rot(vips, :VIPS_ANGLE_D270)

  # Any other angle. libvips `rotate` turns anticlockwise, so negate for clockwise.
  # If the result looks backwards next to the browser preview, flip the sign.
  defp transform(vips, "rotate", %{rotation: deg}) do
    with {:ok, vips} <- flatten_alpha(vips) do
      Vix.Vips.Operation.rotate(vips, -deg * 1.0, background: [255.0, 255.0, 255.0])
    end
  end

  # Invert would also invert the alpha channel, so flatten transparency to white first.
  defp transform(vips, "invert", %{inverted: true}) do
    with {:ok, vips} <- flatten_alpha(vips), do: Vix.Vips.Operation.invert(vips)
  end

  defp transform(vips, "invert", _image), do: {:ok, vips}

  # compress / convert -> always JPEG, so transparency becomes white
  defp transform(vips, _compress_or_convert, _image), do: flatten_alpha(vips)

  defp flatten_alpha(vips) do
    if Vix.Vips.Image.has_alpha?(vips) do
      Vix.Vips.Operation.flatten(vips, background: [255.0, 255.0, 255.0])
    else
      {:ok, vips}
    end
  end

  # libvips JPEG quality runs 1..100, so 0 is saved as 1.
  defp save_target(path, operation, image) when operation in ["compress", "convert"],
    do: path <> "[Q=#{max(image.quality, 1)}]"

  # rotate / invert keep the original format; keep JPEGs high quality.
  defp save_target(path, _operation, _image) do
    if Path.extname(path) in [".jpg", ".jpeg"], do: path <> "[Q=95]", else: path
  end

  defp copy_original(path, id, client_name) do
    File.mkdir_p!(@original_dir)
    dest = Path.join(@original_dir, id <> String.downcase(Path.extname(client_name)))
    File.cp!(path, dest)
    dest
  end

  defp create_thumbnail(path, id) do
    File.mkdir_p!(@thumb_dir)

    thumbnail_path = "#{@thumb_dir}/#{id}.jpg"

    {:ok, image} = Vix.Vips.Image.new_from_file(path)
    {:ok, thumbnail} = Vix.Vips.Operation.thumbnail_image(image, 150, height: 150)
    :ok = Vix.Vips.Image.write_to_file(thumbnail, thumbnail_path)

    "/uploads/thumbnails/#{id}.jpg"
  end

  # --------------------------------------------------
  # Helpers: zip for groups (ZIP, not RAR: RAR can't be created without a licensed tool)
  # --------------------------------------------------

  # two files named photo.png / photo.jpg both become photo.jpg -> "photo (1).jpg"
  defp dedupe_filenames(results) do
    {renamed, _seen} =
      Enum.map_reduce(results, %{}, fn result, seen ->
        count = Map.get(seen, result.filename, 0)

        name =
          if count == 0,
            do: result.filename,
            else: "#{Path.rootname(result.filename)} (#{count})#{Path.extname(result.filename)}"

        {%{result | filename: name}, Map.put(seen, result.filename, count + 1)}
      end)

    renamed
  end

  defp build_zip(results) do
    File.mkdir_p!(@zip_dir)

    zip_name =
      "imagepro-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false) <> ".zip"

    zip_path = Path.join(@zip_dir, zip_name)

    files = Enum.map(results, &{String.to_charlist(&1.filename), File.read!(&1.path)})
    {:ok, _} = :zip.create(String.to_charlist(zip_path), files)

    "/uploads/zips/" <> zip_name
  end
end
