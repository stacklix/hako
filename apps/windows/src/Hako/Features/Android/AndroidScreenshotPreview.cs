using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;

namespace Hako.Platform;

internal static class AndroidScreenshotPreview
{
    internal const int MaximumBytes = 40 * 1024;
    internal static byte[] Create(byte[] png)
    {
        using var input = new MemoryStream(png, writable: false);
        using var image = Image.FromStream(input, useEmbeddedColorManagement: false, validateImageData: true);
        if ((long)image.Width * image.Height > 40_000_000) throw new InvalidDataException("截图尺寸超过预览限制。");
        var scale = Math.Min(1, Math.Min(720.0 / image.Width, 1600.0 / image.Height));
        var codec = ImageCodecInfo.GetImageEncoders().Single(value => value.FormatID == ImageFormat.Jpeg.Guid);
        while (true)
        {
            var width = Math.Max(1, (int)(image.Width * scale));
            var height = Math.Max(1, (int)(image.Height * scale));
            using var bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.Black);
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(image, 0, 0, width, height);
            }
            foreach (var quality in new long[] { 70, 50, 35 })
            {
                using var output = new MemoryStream();
                using var parameters = new EncoderParameters(1);
                parameters.Param[0] = new EncoderParameter(Encoder.Quality, quality);
                bitmap.Save(output, codec, parameters);
                if (output.Length <= MaximumBytes) return output.ToArray();
            }
            if (width == 1 && height == 1) throw new InvalidDataException("无法生成截图预览。");
            scale *= 0.75;
        }
    }
}
