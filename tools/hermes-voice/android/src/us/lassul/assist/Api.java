package us.lassul.assist;

import android.content.Context;
import android.content.SharedPreferences;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * hermes-voice's API (tools/hermes-voice/hermes_voice.py) behind assist.lassul.us/app/, where the
 * proxy passes the app's own bearer token through instead of asking for the web login.
 */
final class Api {
    private static final String BASE = "https://assist.lassul.us/app";
    private static final String PREFS = "api";

    /** An answer other than 2xx, with the server's error text. */
    static final class Failure extends IOException {
        Failure(String message) {
            super(message);
        }
    }

    private final String token;

    private Api(String token) {
        this.token = token;
    }

    /** Null until the token is set (SetupActivity). */
    static Api load(Context context) {
        String token = prefs(context).getString("token", null);
        return token == null || token.isEmpty() ? null : new Api(token);
    }

    static void saveToken(Context context, String token) {
        prefs(context).edit().putString("token", token.trim()).apply();
    }

    static boolean hasToken(Context context) {
        return load(context) != null;
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    JSONObject get(String path) throws IOException, JSONException {
        HttpURLConnection connection = open(path, "GET");
        try {
            return answer(connection);
        } finally {
            connection.disconnect();
        }
    }

    JSONObject post(String path, JSONObject body) throws IOException, JSONException {
        HttpURLConnection connection = open(path, "POST");
        try {
            send(connection, body);
            return answer(connection);
        } finally {
            connection.disconnect();
        }
    }

    /**
     * A POST whose answer is read as a stream (/delegate's NDJSON); the caller reads and
     * disconnects. Throws Failure on an error answer.
     */
    HttpURLConnection stream(String path, JSONObject body) throws IOException, JSONException {
        HttpURLConnection connection = open(path, "POST");
        // The server writes a keepalive line every 10 s, so a long silence means it is gone.
        connection.setReadTimeout(60_000);
        send(connection, body);
        int status = connection.getResponseCode();
        if (status / 100 != 2) {
            String error = errorOf(connection, status);
            connection.disconnect();
            throw new Failure(error);
        }
        return connection;
    }

    private HttpURLConnection open(String path, String method) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(BASE + path).openConnection();
        connection.setRequestMethod(method);
        connection.setRequestProperty("Authorization", "Bearer " + token);
        connection.setConnectTimeout(10_000);
        connection.setReadTimeout(30_000);
        return connection;
    }

    private static void send(HttpURLConnection connection, JSONObject body) throws IOException {
        byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
        connection.setDoOutput(true);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setFixedLengthStreamingMode(bytes.length);
        try (OutputStream out = connection.getOutputStream()) {
            out.write(bytes);
        }
    }

    private static JSONObject answer(HttpURLConnection connection)
            throws IOException, JSONException {
        int status = connection.getResponseCode();
        if (status / 100 != 2) {
            throw new Failure(errorOf(connection, status));
        }
        return new JSONObject(read(connection.getInputStream()));
    }

    private static String errorOf(HttpURLConnection connection, int status) {
        try {
            InputStream stream = connection.getErrorStream();
            if (stream != null) {
                return new JSONObject(read(stream)).optString("error", "HTTP " + status);
            }
        } catch (IOException | JSONException ignored) {
            // The status says enough.
        }
        return "HTTP " + status;
    }

    private static String read(InputStream stream) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        try (InputStream in = stream) {
            for (int n; (n = in.read(buffer)) > 0; ) {
                out.write(buffer, 0, n);
            }
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }
}
