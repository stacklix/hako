package me.stackli.hako;

import android.graphics.Bitmap;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.MotionEvent;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/** Android 4.4 screen/control source. Uses the existing Hako H.264 packet format. */
public final class LegacyVideoServer {
    private static volatile boolean stopped;
    private static final Class<?> SC;
    static {
        try { SC = Class.forName("android.view.SurfaceControl"); }
        catch (Exception error) { throw new ExceptionInInitializerError(error); }
    }
    private static Object call(String name, Class<?>[] types, Object... args) throws Exception {
        return SC.getMethod(name, types).invoke(null, args);
    }
    private static int field(Object info, String name) throws Exception {
        return info.getClass().getField(name).getInt(info);
    }
    private static final class Display {
        final int width, height, rotation;
        Display() throws Exception {
            Class<?> manager = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object instance = manager.getMethod("getInstance").invoke(null);
            Object info = manager.getMethod("getDisplayInfo", int.class).invoke(instance, 0);
            if (info == null) throw new IOException("No default display");
            width = field(info, "logicalWidth"); height = field(info, "logicalHeight"); rotation = field(info, "rotation");
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096) throw new IOException("Invalid display size");
        }
        boolean same(Display other) { return width == other.width && height == other.height && rotation == other.rotation; }
        int encoded(int side) {
            float scale = Math.min(1f, 1024f / Math.max(width, height));
            return Math.max(16, ((int)(side * scale)) & ~15);
        }
    }
    private static void control(final LocalSocket socket) {
        long downTime = 0;
        MotionEvent last = null;
        Object manager = null;
        Method inject = null;
        try {
            Class<?> type = Class.forName("android.hardware.input.InputManager");
            manager = type.getMethod("getInstance").invoke(null);
            inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
            DataInputStream input = new DataInputStream(socket.getInputStream());
            byte[] packet = new byte[32];
            while (!stopped) {
                input.readFully(packet);
                ByteBuffer b = ByteBuffer.wrap(packet);
                int kind = b.get() & 255, action = b.get() & 255;
                long pointer = b.getLong();
                int x = b.getInt(), y = b.getInt(), width = b.getShort() & 65535, height = b.getShort() & 65535;
                int pressure = b.getShort() & 65535;
                if (kind != 2 || action > 3 || pointer != 0 || width == 0 || height == 0 || width > 4096 || height > 4096
                    || x < 0 || y < 0 || x >= width || y >= height || b.getLong() != 0
                    || pressure != ((action == 1 || action == 3) ? 0 : 65535)
                    || (action == 0 ? last != null : last == null)) throw new IOException("Invalid touch packet");
                Display display = new Display();
                long now = SystemClock.uptimeMillis();
                if (action == 0) downTime = now;
                MotionEvent event = MotionEvent.obtain(downTime, now, action,
                    (float)x * display.width / width, (float)y * display.height / height,
                    pressure / 65535f, 1, 0, 1, 1, 0, 0);
                event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
                if (!Boolean.TRUE.equals(inject.invoke(manager, event, 2))) { event.recycle(); throw new IOException("Touch injection denied"); }
                if (last != null) last.recycle();
                last = (action == 1 || action == 3) ? null : MotionEvent.obtain(event);
                event.recycle();
            }
        } catch (Exception error) {
            if (!stopped && !(error instanceof java.io.EOFException)) System.err.println("Hako touch: " + error);
        } finally {
            if (last != null) {
                last.setAction(MotionEvent.ACTION_CANCEL);
                try { inject.invoke(manager, last, 2); } catch (Exception ignored) { }
                last.recycle();
            }
            stopped = true;
            try { socket.close(); } catch (IOException ignored) { }
        }
    }
    private static int clamp(int value) { return value < 0 ? 0 : value > 255 ? 255 : value; }
    private static void yuv(int[] pixels, byte[] bytes, int width, int height, boolean planar) {
        int frame = width * height;
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            int color = pixels[y * width + x], r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
            bytes[y * width + x] = (byte)clamp(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
            if ((y & 1) == 0 && (x & 1) == 0) {
                int u = clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
                int v = clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
                int chroma = (y / 2) * (width / 2) + x / 2;
                if (planar) { bytes[frame + chroma] = (byte)u; bytes[frame + frame / 4 + chroma] = (byte)v; }
                else { bytes[frame + chroma * 2] = (byte)u; bytes[frame + chroma * 2 + 1] = (byte)v; }
            }
        }
    }
    private static Display encode(DataOutputStream output, Display display) throws Exception {
        int width = display.encoded(display.width), height = display.encoded(display.height);
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", width, height);
        format.setInteger(MediaFormat.KEY_BIT_RATE, 2000000);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 10);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        MediaCodec codec = null;
        boolean started = false;
        try {
            codec = MediaCodec.createEncoderByType("video/avc");
            boolean semi = false, planar = false;
            for (int color : codec.getCodecInfo().getCapabilitiesForType("video/avc").colorFormats) {
                if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) semi = true;
                if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) planar = true;
            }
            if (!semi && !planar) throw new IOException("No YUV420 H.264 encoder");
            planar = !semi;
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, planar
                ? MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar : MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            codec.start(); started = true;
            ByteBuffer[] inputs = codec.getInputBuffers();
            int[] pixels = new int[width * height];
            byte[] image = new byte[width * height * 3 / 2];
            long captured = -100;
            ByteBuffer[] buffers = codec.getOutputBuffers();
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long checked = SystemClock.uptimeMillis();
            while (!stopped) {
                long now = SystemClock.uptimeMillis();
                if (now - captured >= 100) {
                    int input = codec.dequeueInputBuffer(0);
                    if (input >= 0) {
                        // Old Qualcomm ROMs reject opaque Surface buffers, even in
                        // their own screenrecord. Feed an ordinary YUV420 buffer.
                        Bitmap bitmap = (Bitmap)call("screenshot", new Class<?>[]{int.class, int.class}, width, height);
                        if (bitmap == null) throw new IOException("Screen capture unavailable");
                        try { bitmap.getPixels(pixels, 0, width, 0, 0, width, height); }
                        finally { bitmap.recycle(); }
                        yuv(pixels, image, width, height, planar);
                        ByteBuffer buffer = inputs[input]; buffer.clear();
                        if (buffer.remaining() < image.length) throw new IOException("Encoder input buffer too small");
                        buffer.put(image);
                        codec.queueInputBuffer(input, 0, image.length, SystemClock.uptimeMillis() * 1000, 0);
                        captured = now;
                    }
                }
                int index = codec.dequeueOutputBuffer(info, 10000);
                if (index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) buffers = codec.getOutputBuffers();
                else if (index >= 0) {
                    try {
                        if (info.size > 0) {
                            if (info.size > 2 * 1024 * 1024) throw new IOException("Video frame too large");
                            ByteBuffer buffer = buffers[index];
                            buffer.position(info.offset); buffer.limit(info.offset + info.size);
                            byte[] bytes = new byte[info.size]; buffer.get(bytes);
                            long flags = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 ? Long.MIN_VALUE : info.presentationTimeUs;
                            if ((info.flags & MediaCodec.BUFFER_FLAG_SYNC_FRAME) != 0) flags |= 1L << 62;
                            output.writeLong(flags); output.writeInt(bytes.length); output.write(bytes); output.flush();
                        }
                    } finally { codec.releaseOutputBuffer(index, false); }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) throw new IOException("Encoder ended");
                }
                if (SystemClock.uptimeMillis() - checked >= 500) {
                    Display next = new Display();
                    if (!display.same(next)) return next;
                    checked = SystemClock.uptimeMillis();
                }
            }
            return display;
        } finally {
            if (codec != null) { if (started) try { codec.stop(); } catch (Exception ignored) { } codec.release(); }
        }
    }
    public static void main(String[] args) {
        if (args.length != 1 || !args[0].matches("hako_video_[a-f0-9]{32}")) { System.err.println("Invalid socket name"); System.exit(1); }
        try {
            final LocalServerSocket server = new LocalServerSocket(args[0]);
            // Never leave an orphan app_process if the host disappears before connecting.
            Thread watchdog = new Thread(new Runnable() { public void run() {
                try { Thread.sleep(15000); if (!connected) System.exit(1); } catch (InterruptedException ignored) { }
            }});
            watchdog.setDaemon(true); watchdog.start();
            final LocalSocket video = server.accept();
            final LocalSocket input = server.accept();
            connected = true; server.close();
            Thread controls = new Thread(new Runnable() { public void run() { control(input); }});
            controls.setDaemon(true); controls.start();
            try {
                DataOutputStream output = new DataOutputStream(video.getOutputStream());
                Display display = new Display();
                output.writeInt(0x68323634); output.writeInt(display.encoded(display.width)); output.writeInt(display.encoded(display.height)); output.flush();
                while (!stopped) display = encode(output, display);
            } catch (IOException error) {
                if (!stopped) throw error;
            } finally { stopped = true; input.close(); video.close(); }
        } catch (Exception error) { error.printStackTrace(System.err); System.exit(1); }
        System.exit(0);
    }
    private static volatile boolean connected;
}
