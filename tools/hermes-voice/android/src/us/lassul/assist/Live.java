package us.lassul.assist;

import java.util.ArrayList;
import java.util.List;

/**
 * Tells the screens that the call state or a conversation changed, so they redraw while a call
 * runs. Main thread only; the app's screens and CallService share the process.
 */
final class Live {
    private static final List<Runnable> watchers = new ArrayList<>();

    private Live() {}

    static void watch(Runnable watcher) {
        watchers.add(watcher);
    }

    static void unwatch(Runnable watcher) {
        watchers.remove(watcher);
    }

    static void changed() {
        for (Runnable watcher : new ArrayList<>(watchers)) {
            watcher.run();
        }
    }
}
