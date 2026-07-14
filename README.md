# SDR to HDR Perceptual Pipeline

This project is a real-time WebGL 2.0 demonstration of simulating a High Dynamic Range (HDR) expansion pipeline on Standard Dynamic Range (SDR) images, specifically targeting BT.2020 color space with an ACES Filmic tonemapping curve for visual feedback on SDR monitors.

## Intent

Standard images (sRGB / BT.709) only contain pixel data in the `[0, 1]` range. True HDR displays (like OLEDs with 1000+ nits) expect pixel values to extend far beyond `1.0` (often referred to as "headroom"). 

The core aim of this project is to take a flat, SDR image and perceptually **expand its highlights** and **lift its shadows** into a wide-gamut (BT.2020), high-dynamic-range (RGBA16F float buffer) space, simulating how an image might be processed for an HDR screen. Because this is viewed on standard monitors, we then compress that expanded headroom back down into a viewable range using an ACES Filmic tonemapping curve so you can visually perceive the "headroom" expansion without the colors clipping to white.

## Project Architecture (Two-Pass Pipeline)

Because standard HTML5 `<canvas>` elements natively clip color values at `1.0`, we must use a **Two-Pass WebGL Architecture** to preserve HDR data mathematically.

### Pass 1: HDR Expansion (Computed to RGBA16F Buffer)
File: `shaders/hdr_pass.glsl`

1. **Color Space Conversion**: The sRGB input is converted into the BT.2020 wide color gamut.
2. **Luminance Extraction**: We calculate the perceptual brightness (luma) of each pixel using standard BT.2020 luma coefficients.
3. **Shadow Lifting**: Pixels below the user-defined `Shadow Pivot` are boosted smoothly according to `Shadow Gain`.
4. **Highlight Expansion (Inverse Reinhard)**: Pixels above the user-defined `Highlight Pivot` are mathematically expanded beyond `1.0` into an infinite scale, controlled by the `Highlight Strength`. 
5. **Data Storage**: The result is rendered into an off-screen `RGBA16F` Framebuffer Object (FBO). This float buffer allows pixels to store brightness values of `2.0`, `10.0`, or higher without clipping!

### Pass 2: Display Mapping (Rendered to Screen)
File: `shaders/display_pass.glsl`

Since the off-screen float buffer contains values > `1.0`, simply drawing it to the screen would cause blown-out white highlights. We must tonemap it.

1. **ACES Filmic Tonemap**: We apply the ACES (Academy Color Encoding System) filmic curve. This gently rolls off super-bright values back down into the `[0.0, 1.0]` range, preserving contrast and detail in the highlights rather than clipping them.
2. **Luminance Preservation**: To prevent "hue shift" (where tonemapping RGB channels independently causes saturated bright colors to wash out to white), we only tonemap the *luminance* and scale the RGB channels proportionally.
3. **Output**: The image is mapped back to BT.709 (sRGB) for final display on standard web monitors.

## The Grid

The WebGL shader dynamically divides the screen into four quadrants to compare the pipeline stages side-by-side:

1. **BT.709 SDR (Original)**: The unmodified image.
2. **Raw HDR Expansion**: Applies the raw HDR expansion math without the ACES tonemap. On an SDR monitor, the expanded data instantly clips to white, vividly showing exactly how much headroom the sliders are generating.
3. **ACES Tonemapped**: The full SDR → HDR expansion, gracefully compressed back for viewing. You can see how contrast and detail are maintained in bright areas.
4. **Luma Analysis**: A dynamic diagnostic view. Highlights (above your chosen `Highlight Pivot`) are colored green, and Shadows (below your chosen `Shadow Pivot`) are colored blue. 

## Features

- **Interactive UI Sliders**: Adjust the math driving the Inverse Reinhard expansion in real-time at 60fps.
- **Smart Image Uploads**: Upload your own imagery. The system automatically enforces a 12-Megapixel (3000x4000) memory budget by proportionately downscaling massive images via 2D Canvas before passing them to the WebGL texture memory.
- **Responsive Layout**: The app seamlessly transitions from a Desktop 2x2 grid split-view to a Mobile 1x4 vertical-scroll app view on screens smaller than 768px.
- **Download HDR**: Instantly export a clean, full-resolution PNG of the ACES Tonemapped output (Panel 3) using a synchronized full-screen render pass. 

## Usage

1. Open `index.html` in any WebGL 2.0 compatible browser (or serve it via a local static server like `http-server`).
2. Click **Upload Image** to test your own SDR images.
3. Play with the **Tone Mapping Parameters** panel and watch the diagnostic Luma Analysis and Raw HDR Expansion panels react instantly.
4. Click **Download HDR** to export the tonemapped result!

## License

This project is licensed under the [MIT License](LICENSE).
