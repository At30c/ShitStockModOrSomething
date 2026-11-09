package io.unica.fota;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.Network;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * UN1CA: serves an update package that is published in parts (each under the
 * 2 GiB GitHub release asset limit) as one file on 127.0.0.1, so the stock
 * DlAgent downloads it unchanged: progress, resume (Range), MD5 check and
 * install all keep working, and the package is written whole.
 *
 *   GET /unica/dd.xml       the download descriptor, objectURI rewritten to
 *                           the package below
 *   GET /unica/package.bin  the parts joined, with Range support; each
 *                           request fetches only the needed byte range of
 *                           the needed part(s)
 *
 * The descriptor and the part list are kept in SharedPreferences, so the
 * proxy comes back with the app process (IDMApplication.onCreate) and a
 * download resumed after a reboot still finds it. The parts are public
 * release files; the proxy exposes nothing else.
 *
 * Each package request is tied to the network that was active when DlAgent
 * made it, and is cut when that changes, so a Wi-Fi-only download never
 * continues over mobile data (DlAgent's own socket is local and would not
 * notice the change).
 */
public final class PartProxy {
    private static final String TAG = "UnicaFota";
    static final int PORT = 47821;
    static final String BASE = "http://127.0.0.1:" + PORT;
    static final String DD_URL = BASE + "/unica/dd.xml";
    static final String PACKAGE_URL = BASE + "/unica/package.bin";

    private static final String PREFS = "unica_fota_parts";
    private static final String KEY_DD = "dd";
    private static final String KEY_PARTS = "parts";
    private static final int TIMEOUT_MS = 30000;
    private static final long NETWORK_CHECK_MS = 1000;

    private static Context appContext;
    private static ServerSocket server;

    private PartProxy() {}

    private static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    /** Called from IDMApplication.onCreate: restart the proxy for a pending download. */
    public static void startIfPending(Context context) {
        try {
            if (prefs(context).contains(KEY_PARTS)) {
                start(context);
            }
        } catch (Throwable t) {
            Log.e(TAG, "part proxy: cannot start", t);
        }
    }

    /** Stores a split package and starts serving it. */
    static void publish(Context context, String dd, JSONArray parts) throws IOException {
        prefs(context).edit().putString(KEY_DD, dd).putString(KEY_PARTS, parts.toString()).commit();
        start(context);
    }

    /** Forgets the split package (the proxy then answers 404). */
    static void clear(Context context) {
        prefs(context).edit().remove(KEY_DD).remove(KEY_PARTS).commit();
    }

    private static synchronized void start(Context context) throws IOException {
        appContext = context.getApplicationContext();
        if (server != null && !server.isClosed()) {
            return;
        }
        ServerSocket s = new ServerSocket();
        s.setReuseAddress(true);
        s.bind(new java.net.InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT));
        server = s;
        Thread t = new Thread(() -> acceptLoop(s), "UnicaFotaProxy");
        t.setDaemon(true);
        t.start();
        Log.i(TAG, "part proxy listening on " + BASE);
    }

    private static void acceptLoop(ServerSocket s) {
        while (!s.isClosed()) {
            try {
                Socket c = s.accept();
                Thread t = new Thread(() -> handle(c), "UnicaFotaProxyConn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                if (!s.isClosed()) Log.w(TAG, "part proxy accept failed", e);
            }
        }
    }

    private static String readLine(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int b;
        while ((b = in.read()) != -1) {
            if (b == '\n') break;
            if (b != '\r') sb.append((char) b);
            if (sb.length() > 8192) throw new IOException("header line too long");
        }
        if (b == -1 && sb.length() == 0) return null;
        return sb.toString();
    }

    private static void writeHead(OutputStream out, String status, String type, long length,
            String extra) throws IOException {
        StringBuilder h = new StringBuilder();
        h.append("HTTP/1.1 ").append(status).append("\r\n");
        if (type != null) h.append("Content-Type: ").append(type).append("\r\n");
        h.append("Content-Length: ").append(length).append("\r\n");
        h.append("Accept-Ranges: bytes\r\n");
        if (extra != null) h.append(extra);
        h.append("Connection: close\r\n\r\n");
        out.write(h.toString().getBytes(StandardCharsets.US_ASCII));
    }

    private static void handle(Socket c) {
        try (Socket sock = c) {
            sock.setSoTimeout(TIMEOUT_MS);
            InputStream in = sock.getInputStream();
            OutputStream out = new BufferedOutputStream(sock.getOutputStream(), 65536);

            String request = readLine(in);
            if (request == null) return;
            String range = null;
            String line;
            while ((line = readLine(in)) != null && !line.isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase("Range")) {
                    range = line.substring(colon + 1).trim();
                }
            }
            String[] req = request.split(" ");
            if (req.length < 2) return;
            String method = req[0];
            String path = req[1];
            int q = path.indexOf('?');
            if (q >= 0) path = path.substring(0, q);
            boolean head = method.equals("HEAD");
            Log.i(TAG, "part proxy: " + method + " " + path + (range != null ? " " + range : ""));

            SharedPreferences p = prefs(appContext);
            String dd = p.getString(KEY_DD, null);
            String partsJson = p.getString(KEY_PARTS, null);
            if (dd == null || partsJson == null || !(method.equals("GET") || head)) {
                writeHead(out, "404 Not Found", null, 0, null);
                out.flush();
                return;
            }

            if (path.equals("/unica/dd.xml")) {
                byte[] body = dd.getBytes(StandardCharsets.UTF_8);
                writeHead(out, "200 OK", "text/xml; charset=utf-8", body.length, null);
                if (!head) out.write(body);
                out.flush();
                return;
            }
            if (!path.equals("/unica/package.bin")) {
                writeHead(out, "404 Not Found", null, 0, null);
                out.flush();
                return;
            }

            JSONArray parts = new JSONArray(partsJson);
            int n = parts.length();
            String[] urls = new String[n];
            long[] starts = new long[n + 1];
            for (int i = 0; i < n; i++) {
                JSONObject part = parts.getJSONObject(i);
                urls[i] = part.getString("url");
                starts[i + 1] = starts[i] + part.getLong("size");
            }
            long total = starts[n];

            long from = 0;
            long to = total - 1;
            boolean partial = false;
            if (range != null && range.startsWith("bytes=")) {
                String spec = range.substring(6);
                int dash = spec.indexOf('-');
                if (dash < 0 || spec.indexOf(',') >= 0) {
                    writeHead(out, "416 Range Not Satisfiable", null, 0,
                            "Content-Range: bytes */" + total + "\r\n");
                    out.flush();
                    return;
                }
                String a = spec.substring(0, dash).trim();
                String b = spec.substring(dash + 1).trim();
                if (a.isEmpty()) {
                    from = Math.max(0, total - Long.parseLong(b));
                } else {
                    from = Long.parseLong(a);
                    if (!b.isEmpty()) to = Math.min(to, Long.parseLong(b));
                }
                if (from >= total || from > to) {
                    writeHead(out, "416 Range Not Satisfiable", null, 0,
                            "Content-Range: bytes */" + total + "\r\n");
                    out.flush();
                    return;
                }
                partial = true;
            }

            long length = to - from + 1;
            if (partial) {
                writeHead(out, "206 Partial Content", "application/octet-stream", length,
                        "Content-Range: bytes " + from + "-" + to + "/" + total + "\r\n");
            } else {
                writeHead(out, "200 OK", "application/octet-stream", length, null);
            }
            if (head) {
                out.flush();
                return;
            }

            // DlAgent's own socket is local and never sees the network change,
            // so tie the upstream side to the network active now and drop the
            // transfer when it changes. DlAgent then applies its network policy
            // (e.g. Wi-Fi only) and resumes with Range, as it would with a
            // direct connection.
            ConnectivityManager cm = appContext.getSystemService(ConnectivityManager.class);
            Network net = cm.getActiveNetwork();
            if (net == null) throw new IOException("no active network");
            long off = from;
            byte[] buf = new byte[65536];
            for (int i = 0; i < n && off <= to; i++) {
                if (off >= starts[i + 1]) continue;
                long partFrom = off - starts[i];
                long partTo = Math.min(to, starts[i + 1] - 1) - starts[i];
                long want = partTo - partFrom + 1;
                copyPart(cm, net, urls[i], partFrom, partTo, want, out, buf);
                off += want;
            }
            out.flush();
        } catch (Throwable t) {
            // Closing the socket mid-body tells DlAgent the transfer broke; it
            // resumes from what it has with a new Range request.
            Log.w(TAG, "part proxy: transfer aborted", t);
        }
    }

    private static void copyPart(ConnectivityManager cm, Network net, String url, long from,
            long to, long want, OutputStream out, byte[] buf) throws IOException {
        HttpURLConnection c = (HttpURLConnection) net.openConnection(new URL(url));
        try {
            c.setConnectTimeout(TIMEOUT_MS);
            c.setReadTimeout(TIMEOUT_MS);
            c.setInstanceFollowRedirects(true);
            c.setUseCaches(false);
            c.setRequestProperty("Range", "bytes=" + from + "-" + to);
            int code = c.getResponseCode();
            long skip;
            if (code == HttpURLConnection.HTTP_PARTIAL) {
                skip = 0;
            } else if (code == HttpURLConnection.HTTP_OK) {
                // Host ignored Range: skip to the wanted offset.
                skip = from;
            } else {
                throw new IOException("HTTP " + code + " for " + url);
            }
            try (InputStream in = c.getInputStream()) {
                while (skip > 0) {
                    long s = in.skip(skip);
                    if (s <= 0) {
                        if (in.read() < 0) throw new IOException("short part " + url);
                        s = 1;
                    }
                    skip -= s;
                }
                long left = want;
                long nextCheck = 0;
                while (left > 0) {
                    long now = System.currentTimeMillis();
                    if (now >= nextCheck) {
                        if (!net.equals(cm.getActiveNetwork())) {
                            throw new IOException("network changed");
                        }
                        nextCheck = now + NETWORK_CHECK_MS;
                    }
                    int r = in.read(buf, 0, (int) Math.min(buf.length, left));
                    if (r < 0) throw new IOException("short part " + url);
                    out.write(buf, 0, r);
                    left -= r;
                }
            }
        } finally {
            c.disconnect();
        }
    }
}
