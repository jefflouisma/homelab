package games.fenrir.cove

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.material3.Button
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.input.key.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.coveninja.cove.shared.fixture.FixtureAppGraph
import com.coveninja.cove.ui.CoveTheme
import com.coveninja.cove.ui.model.Media
import com.coveninja.cove.ui.model.MediaType
import com.coveninja.cove.ui.model.MediaVideo
import com.coveninja.cove.ui.state.*
import com.coveninja.cove.ui.tv.TvTheme
import com.coveninja.cove.ui.tv.tvDimensFor
import com.coveninja.cove.ui.tv.player.TvPlayerLayer
import java.awt.EventQueue
import java.awt.KeyboardFocusManager
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.system.exitProcess
import kotlinx.coroutines.flow.MutableStateFlow

private class TestPlayer : VideoPlayerHost {
    override val status = MutableStateFlow(PlaybackStatus())
    val seeks = AtomicInteger()
    val pauses = AtomicInteger()
    override suspend fun prepareWebVideo(mayInstallHelper: Boolean): String? = null
    override fun load(url: String, startPositionSeconds: Double) {
        status.value = PlaybackStatus(hasMedia=true, paused=false, positionSeconds=100.0,
            durationSeconds=600.0, fileLoaded=true, bufferedSeconds=600.0)
    }
    override fun setPaused(paused: Boolean) { status.value=status.value.copy(paused=paused) }
    override fun togglePause() { pauses.incrementAndGet();setPaused(!status.value.paused) }
    override fun seek(seconds: Double) { status.value=status.value.copy(positionSeconds=seconds);seeks.incrementAndGet() }
    override fun seekRelative(deltaSeconds: Double) = seek(status.value.positionSeconds+deltaSeconds)
    override fun setVolume(volume: Double) {}
    override fun setMuted(muted: Boolean) {}
    override fun selectAudioTrack(id: Int) {}
    override fun setScaling(scaling: VideoScaling) {}
    override fun setSpeed(speed: Double) {}
    override fun applyPreferences(preferences: PlaybackPreferences) {}
    override fun addSubtitle(url: String, title: String, language: String, select: Boolean) {}
    override fun selectSubtitleTrack(id: Int?) {}
    override fun stepChapter(delta: Int) {}
    override fun stepFrame(delta: Int) {}
    override fun setSubtitleDelay(seconds: Double) {}
    override fun setAudioDelay(seconds: Double) {}
    override fun takeScreenshot() {}
    override fun stop() {}
    @Composable override fun Surface(modifier: Modifier) {
        Box(modifier.fillMaxSize().background(Color(0xFF13202A))) { Text("Playback controls regression") }
    }
}
private fun waitFor(label: String, condition: () -> Boolean) {
    val deadline=System.nanoTime()+5_000_000_000L
    while (!condition()) {
        check(System.nanoTime()<deadline) { label }
        Thread.sleep(20)
    }
}
private fun send(action: String) {
    EventQueue.invokeAndWait {
        val queue=java.awt.Toolkit.getDefaultToolkit().systemEventQueue
        queue.javaClass.getDeclaredMethod("controller",String::class.java).apply { isAccessible=true }.invoke(queue,action)
    }
    Thread.sleep(80)
}
private fun select() { send("SELECT_DOWN");send("SELECT_RELEASE");send("SELECT_UP") }
private fun menuVisible()=java.awt.Window.getWindows().any { it.isShowing && it.javaClass.name.endsWith("RemoteMenu") }

fun main() {
    val host=TestPlayer()
    CoveRemoteLauncher.premain("")
    application {
        Window(onCloseRequest={exitApplication()},title="Cove playback controls regression",state=rememberWindowState(width=1280.dp,height=720.dp)) {
            val graph=remember { FixtureAppGraph() }
            val scope=rememberCoroutineScope()
            val session=remember { PlaybackSession(graph,scope,host) }
            val backgroundFocus=remember { FocusRequester() }
            val backgroundClicks=remember { AtomicInteger() }
            LaunchedEffect(Unit) {
                session.openExtra(Media(id="remote-regression",tmdbId=0,title="Remote regression",name=null,
                    overview=null,released=null,firstAirDate=null,posterUrl=null,logoUrl=null,backdropUrl=null,
                    rating=null,type=MediaType.Movie,popularity=null,adult=false,originalLanguage="en"),
                    MediaVideo("test-video","Test video",null,url="https://example.invalid/test.mp4"))
                thread(name="playback-check") {
                    try {
                        waitFor("player did not open") { host.status.value.hasMedia }
                        waitFor("Cove window did not focus") { KeyboardFocusManager.getCurrentKeyboardFocusManager().focusOwner != null }
                        Thread.sleep(5500) // Let the actual TV controls auto-hide.
                        // Reproduce focus being on a covered page rather than the player.
                        EventQueue.invokeAndWait { backgroundFocus.requestFocus() }
                        send("RIGHT")
                        waitFor("RIGHT must seek while playback controls are hidden; position=${host.status.value.positionSeconds}") { host.seeks.get()==1 }
                        check(host.status.value.positionSeconds>100.0)
                        send("LEFT")
                        waitFor("LEFT must rewind") { host.seeks.get()==2 }
                        check(host.status.value.positionSeconds==100.0)
                        Thread.sleep(5500)
                        select()
                        waitFor("short OK must pause even when the video has lost child focus") { host.pauses.get()==1 && host.status.value.paused }
                        Thread.sleep(350)
                        select()
                        waitFor("short OK on focused play/pause must resume") { host.pauses.get()==2 && !host.status.value.paused }
                        send("RIGHT");select()
                        waitFor("focused Forward transport button must activate") { host.seeks.get()==3 }
                        check(host.pauses.get()==2)
                        send("LEFT")
                        send("SELECT_DOWN");Thread.sleep(1000);send("SELECT_RELEASE");send("SELECT_UP")
                        waitFor("held OK must still open remote controls") { menuVisible() }
                        check(host.pauses.get()==2) { "hold release must not toggle pause" }
                        send("BACK")
                        waitFor("Back must close the remote menu") { !menuVisible() }
                        select()
                        waitFor("short OK must pause after closing remote menu") { host.pauses.get()==3 && host.status.value.paused }
                        EventQueue.invokeAndWait { session.close() }
                        Thread.sleep(350)
                        EventQueue.invokeAndWait { backgroundFocus.requestFocus() }
                        select()
                        waitFor("closing playback must restore ordinary selection") { backgroundClicks.get()==1 }
                        check(host.pauses.get()==3 && host.seeks.get()==3) { "player callback leaked after close" }
                        println("PASS actual TvPlayerLayer: hidden-controls seek/rewind, reveal, pause/resume, held OK and focus restoration")
                        exitProcess(0)
                    } catch(t:Throwable) { t.printStackTrace();exitProcess(1) }
                }
            }
            CoveTheme {
                TvTheme(tvDimensFor(1280.dp,720.dp)) {
                    CompositionLocalProvider(LocalAppGraph provides graph,LocalVideoPlayerHost provides host) {
                        val focusManager=LocalFocusManager.current
                        Box(Modifier.fillMaxSize().onKeyEvent { event ->
                            if (event.type != KeyEventType.KeyDown) false else {
                                val direction=when(event.key) {
                                    Key.DirectionLeft -> FocusDirection.Left
                                    Key.DirectionRight -> FocusDirection.Right
                                    Key.DirectionUp -> FocusDirection.Up
                                    Key.DirectionDown -> FocusDirection.Down
                                    else -> null
                                }
                                direction != null && focusManager.moveFocus(direction)
                            }
                        }) {
                            Button(onClick={backgroundClicks.incrementAndGet()}, modifier=Modifier.focusRequester(backgroundFocus)) { Text("Covered page button") }
                            TvPlayerLayer(session)
                        }
                    }
                }
            }
        }
    }
}
