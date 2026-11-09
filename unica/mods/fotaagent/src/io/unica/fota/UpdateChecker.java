package io.unica.fota;

import android.content.Context;
import android.os.Handler;
import android.util.Log;

import com.idm.fotaagent.BundleWrapper;
import com.idm.fotaagent.IDMApplication;
import com.idm.fotaagent.database.sqlite.database.dao.ActionInfoDao;
import com.idm.fotaagent.enabler.fumo.IntentManager;
import com.idm.fotaagent.enabler.ui.IDMUIManager;
import com.idm.fotaagent.enabler.ui.interfaces.IDMUIEventInterface;
import com.idm.fotaagent.enabler.ui.notification.manager.NotificationId;
import com.idm.fotaagent.enabler.ui.notification.manager.NotificationTypeManager;
import com.idm.fotaagent.scheduler.IDMSchedulerHandler;
import com.idm.fotaagent.scheduler.interfaces.IDMSchedulerInterface;
import com.idm.service.actioninfo.IDMActionInfo;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.lang.reflect.Field;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * UN1CA: finds ROM updates in the manifest named by ro.unica.ota.manifest,
 * instead of the Samsung FOTA servers.
 *
 * Manifest (JSON):
 * {
 *   "device": "y2s",
 *   "builds": [
 *     { "version": "2.0.2", "timestamp": 1794200000, "dd": "dd-full.xml" },
 *     { "version": "2.0.2", "timestamp": 1794200000,
 *       "base_timestamp": 1794036309, "dd": "dd-incremental.xml" }
 *   ]
 * }
 * "timestamp" is the build's ro.unica.timestamp. An entry with
 * "base_timestamp" is an incremental package and only applies on that build.
 * "dd" is the OMA download descriptor, absolute or relative to the manifest
 * URL. The newest build wins; for the same build an incremental beats a full
 * package.
 *
 * A package larger than the host allows per file (GitHub release assets:
 * 2 GiB) is published in parts, listed in order with their exact sizes:
 *     { "version": "2.0.2", "timestamp": 1794200000, "dd": "dd-full.xml",
 *       "parts": [ { "url": "rom.zip.001", "size": 2097152000 },
 *                  { "url": "rom.zip.002", "size": 1234567 } ] }
 * The descriptor then describes the whole joined file (size and MD5); its
 * objectURI is ignored. PartProxy serves the parts as that one file.
 */
public final class UpdateChecker {
    private static final String TAG = "UnicaFota";
    private static final long DAY_MS = 24L * 60 * 60 * 1000;
    private static final int TIMEOUT_MS = 30000;
    private static final int MAX_MANIFEST_BYTES = 1024 * 1024;
    // R.string.STR_FOTA_LATEST_VERSION
    private static final int STR_FOTA_LATEST_VERSION = 0x7f13006e;

    private UpdateChecker() {}

    /** Thrown when the manifest cannot be fetched or parsed. */
    static final class CheckFailed extends Exception {
        CheckFailed(String msg, Throwable cause) { super(msg, cause); }
    }

    private static String getProp(String key) {
        try {
            Class<?> sp = Class.forName("android.os.SystemProperties");
            return (String) sp.getMethod("get", String.class, String.class)
                    .invoke(null, key, "");
        } catch (Throwable t) {
            return "";
        }
    }

    private static long parseLong(String s) {
        try {
            return Long.parseLong(s.trim());
        } catch (Exception e) {
            return -1;
        }
    }

    private static String fetch(String url) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        try {
            c.setConnectTimeout(TIMEOUT_MS);
            c.setReadTimeout(TIMEOUT_MS);
            c.setInstanceFollowRedirects(true);
            c.setUseCaches(false);
            c.setRequestProperty("Cache-Control", "no-cache");
            int code = c.getResponseCode();
            if (code != HttpURLConnection.HTTP_OK) {
                throw new Exception("HTTP " + code + " for " + url);
            }
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                    if (out.size() > MAX_MANIFEST_BYTES) {
                        throw new Exception("manifest too large");
                    }
                }
                return out.toString("UTF-8");
            }
        } finally {
            c.disconnect();
        }
    }

    /**
     * Returns the download descriptor URL of the update for this build, or
     * null when the build is up to date (or no manifest is configured).
     */
    static String findUpdate(Context context) throws CheckFailed {
        String dd = selectUpdate(context);
        if (dd == null) {
            PartProxy.clear(context);
        }
        return dd;
    }

    private static String selectUpdate(Context context) throws CheckFailed {
        String manifestUrl = getProp("ro.unica.ota.manifest");
        if (manifestUrl.isEmpty()) {
            Log.w(TAG, "ro.unica.ota.manifest is not set; no ROM updates");
            return null;
        }
        long current = parseLong(getProp("ro.unica.timestamp"));
        if (current <= 0) {
            Log.w(TAG, "ro.unica.timestamp is not set; no ROM updates");
            return null;
        }
        String device = getProp("ro.unica.device");

        JSONObject manifest;
        try {
            manifest = new JSONObject(fetch(manifestUrl));
        } catch (Exception e) {
            throw new CheckFailed("cannot read " + manifestUrl, e);
        }

        String forDevice = manifest.optString("device", "");
        if (!forDevice.isEmpty() && !device.isEmpty() && !forDevice.equals(device)) {
            Log.w(TAG, "manifest is for " + forDevice + ", this is " + device);
            return null;
        }

        JSONArray builds = manifest.optJSONArray("builds");
        if (builds == null) {
            throw new CheckFailed("manifest has no builds", null);
        }

        long bestTime = current;
        boolean bestIncremental = false;
        String bestDd = null;
        String bestVersion = null;
        JSONArray bestParts = null;
        for (int i = 0; i < builds.length(); i++) {
            JSONObject b = builds.optJSONObject(i);
            if (b == null) continue;
            long time = b.optLong("timestamp", -1);
            String dd = b.optString("dd", "");
            if (time <= current || dd.isEmpty()) continue;
            boolean incremental = b.has("base_timestamp");
            if (incremental && b.optLong("base_timestamp", -1) != current) continue;
            if (time > bestTime || (time == bestTime && incremental && !bestIncremental)) {
                bestTime = time;
                bestIncremental = incremental;
                bestDd = dd;
                bestVersion = b.optString("version", "");
                bestParts = b.optJSONArray("parts");
            }
        }
        if (bestDd == null) {
            Log.i(TAG, "up to date (" + current + ")");
            return null;
        }
        try {
            bestDd = new URL(new URL(manifestUrl), bestDd).toString();
        } catch (Exception e) {
            throw new CheckFailed("bad dd URL " + bestDd, e);
        }
        Log.i(TAG, "update " + bestVersion + " (" + bestTime + ", "
                + (bestIncremental ? "incremental" : "full")
                + (bestParts != null ? ", " + bestParts.length() + " parts" : "")
                + ") dd=" + bestDd);
        if (bestParts == null) {
            PartProxy.clear(context);
            return bestDd;
        }
        return publishParts(context, manifestUrl, bestDd, bestParts);
    }

    /**
     * Hands a split package to PartProxy: resolves the part URLs, checks that
     * the descriptor size matches the parts, points its objectURI at the
     * proxy and returns the proxy's descriptor URL.
     */
    private static String publishParts(Context context, String manifestUrl, String ddUrl,
            JSONArray parts) throws CheckFailed {
        JSONArray resolved = new JSONArray();
        long total = 0;
        try {
            if (parts.length() == 0) throw new Exception("empty part list");
            for (int i = 0; i < parts.length(); i++) {
                JSONObject p = parts.getJSONObject(i);
                long size = p.getLong("size");
                if (size <= 0) throw new Exception("bad size for part " + i);
                String url = new URL(new URL(manifestUrl), p.getString("url")).toString();
                resolved.put(new JSONObject().put("url", url).put("size", size));
                total += size;
            }
        } catch (Exception e) {
            throw new CheckFailed("bad part list", e);
        }

        String dd;
        try {
            dd = fetch(ddUrl);
        } catch (Exception e) {
            throw new CheckFailed("cannot read " + ddUrl, e);
        }
        Matcher size = Pattern.compile("<size>\\s*(\\d+)\\s*</size>").matcher(dd);
        if (!size.find() || Long.parseLong(size.group(1)) != total) {
            throw new CheckFailed("descriptor size does not match the parts (" + total + ")", null);
        }
        Matcher uri = Pattern.compile("<objectURI>.*?</objectURI>", Pattern.DOTALL).matcher(dd);
        if (!uri.find()) {
            throw new CheckFailed("descriptor has no objectURI", null);
        }
        dd = uri.replaceFirst(Matcher.quoteReplacement(
                "<objectURI>" + PartProxy.PACKAGE_URL + "</objectURI>"));

        try {
            PartProxy.publish(context, dd, resolved);
        } catch (Exception e) {
            throw new CheckFailed("cannot start the part proxy", e);
        }
        return PartProxy.DD_URL;
    }

    /**
     * Periodic check (PollingStartState). Starts the update job when there is
     * an update. Returns false when the manifest could not be read, so the
     * caller keeps the alarm and retries.
     */
    public static boolean poll(Context context) {
        // The stock polling path went through the scheduler, which never
        // starts a session while another job is in progress or pending. Keep
        // that rule: a second job would download into the same update.zip.
        if (jobPending()) {
            Log.i(TAG, "periodic check skipped: an update job is already pending");
            return true;
        }
        try {
            String dd = findUpdate(context);
            if (dd != null) {
                new UpdateReceiver.Job(context, dd).run();
            }
            return true;
        } catch (CheckFailed e) {
            Log.w(TAG, "periodic check failed", e);
            return false;
        }
    }

    /** True when a FUMO job (download, install or result) exists. */
    private static boolean jobPending() {
        try {
            return new ActionInfoDao().getEntity() != null;
        } catch (Throwable t) {
            Log.w(TAG, "cannot read the job table", t);
            return true;
        }
    }

    /** Next periodic check: one day from now, spread over a two-hour window. */
    public static long nextPollingTime() {
        return System.currentTimeMillis() + DAY_MS + new Random().nextInt(2 * 60 * 60 * 1000);
    }

    /**
     * First periodic check after the app registers (first boot, or after an
     * update or a data wipe): 5 to 10 minutes from now.
     */
    public static long firstPollingTime() {
        return System.currentTimeMillis() + 5 * 60 * 1000 + new Random().nextInt(5 * 60 * 1000);
    }

    /**
     * Replaces LibraryStarter.startDMTask() in DmSessionStarter.execute(), so a
     * user (or device) initiated check reads the ROM manifest instead of
     * opening a Samsung DM session. Runs off the caller's thread.
     */
    public static void startDMTask(IDMActionInfo actionInfo) {
        final String taskId = actionInfo.idmGetSessionId();
        new Thread(() -> runUserCheck(taskId), "UnicaFotaCheck").start();
    }

    private static void finishSession(String taskId) {
        IntentManager.sendFotaStatus(taskId);
        NotificationTypeManager.cancel(NotificationId.NOTIFICATION_ID_PRIMARY);
        IDMSchedulerHandler.getInstance().idmSendMessage(
                IDMSchedulerInterface.IDM_SCHEDULE_EVENT.SCHEDULE_EVENT_SCHEDULE_FINISH, taskId, 0);
    }

    /**
     * Returns once the scheduler has handled every message queued so far
     * (SCHEDULE_FINISH) and whatever that queued next. The scheduler runs its
     * messages in order on IDMSchedulerHandler.handler.
     */
    private static void waitForScheduler() {
        try {
            Field f = IDMSchedulerHandler.class.getDeclaredField("handler");
            f.setAccessible(true);
            final Handler h = (Handler) f.get(IDMSchedulerHandler.getInstance());
            final CountDownLatch done = new CountDownLatch(1);
            h.post(() -> h.post(done::countDown));
            if (done.await(15, TimeUnit.SECONDS)) {
                return;
            }
            Log.w(TAG, "scheduler still busy, starting the job anyway");
        } catch (Throwable t) {
            Log.w(TAG, "cannot reach the scheduler queue; waiting instead", t);
            try {
                Thread.sleep(3000);
            } catch (InterruptedException ignored) {
            }
        }
    }

    private static void runUserCheck(String taskId) {
        String dd;
        try {
            dd = findUpdate(IDMApplication.idmGetContext());
        } catch (CheckFailed e) {
            Log.w(TAG, "update check failed", e);
            finishSession(taskId);
            IDMUIManager.getInstance().sendDialogMessage(
                    IDMUIEventInterface.UIDIALOG.IDM_DIALOG_CONNECT_FAIL);
            return;
        } catch (Throwable t) {
            Log.e(TAG, "update check crashed", t);
            finishSession(taskId);
            return;
        }
        // Close the check session first: the update runs as its own job. The
        // scheduler finalizes the session on its own thread and that cleanup
        // also drops any job created meanwhile, so wait for it.
        finishSession(taskId);
        waitForScheduler();
        if (dd != null && jobPending()) {
            Log.i(TAG, "update found, but an update job is already pending");
            return;
        }
        if (dd == null) {
            IDMUIManager.getInstance().sendActivityMessageDelayed(
                    IDMUIEventInterface.UIACTIVITY.NO_UPDATABLE_VERSION,
                    new BundleWrapper().setResourceId(STR_FOTA_LATEST_VERSION), 667);
            return;
        }
        new UpdateReceiver.Job(IDMApplication.idmGetContext(), dd).run();
    }
}
