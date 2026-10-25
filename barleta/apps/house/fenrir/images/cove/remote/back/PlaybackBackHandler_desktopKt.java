package com.coveninja.cove.ui.platform;

import androidx.compose.runtime.Composer;
import androidx.compose.runtime.DisposableEffectResult;
import androidx.compose.runtime.EffectsKt;
import games.fenrir.cove.CoveRemoteLauncher;
import kotlin.Unit;
import kotlin.jvm.functions.Function0;

/** ABI-compatible implementation of the pinned release's no-op desktop actual. */
public final class PlaybackBackHandler_desktopKt {
    private PlaybackBackHandler_desktopKt() { }

    public static void PlatformBackHandler(boolean enabled, Function0<Unit> onBack, Composer composer, int changed) {
        composer.startReplaceGroup(2033691701);
        EffectsKt.DisposableEffect(enabled, onBack, scope -> {
            if (!enabled) return (DisposableEffectResult) () -> { };
            Runnable remove = CoveRemoteLauncher.registerBackHandler(() -> onBack.invoke());
            return (DisposableEffectResult) remove::run;
        }, composer, 0);
        composer.endReplaceGroup();
    }
}
