#include <SDL2/SDL.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static SDL_Joystick *ensure_controller(SDL_JoystickID *instance) {
    if (!(SDL_WasInit(SDL_INIT_GAMECONTROLLER) & SDL_INIT_GAMECONTROLLER)) return NULL;
    SDL_Joystick *existing = SDL_JoystickFromInstanceID(*instance);
    if (existing) return existing;
    SDL_VirtualJoystickDesc descriptor;
    memset(&descriptor, 0, sizeof(descriptor));
    descriptor.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    descriptor.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    descriptor.naxes = 6;
    descriptor.nbuttons = 15;
    descriptor.vendor_id = 0x045e;
    descriptor.product_id = 0x02ea;
    descriptor.button_mask = 0x7fff;
    descriptor.axis_mask = 0x3f;
    descriptor.name = "FenrirTestController";
    int index = SDL_JoystickAttachVirtualEx(&descriptor);
    SDL_GameController *controller = index >= 0 ? SDL_GameControllerOpen(index) : NULL;
    if (!controller) {
        if (index >= 0) SDL_JoystickDetachVirtual(index);
        return NULL;
    }
    SDL_Joystick *joystick = SDL_GameControllerGetJoystick(controller);
    *instance = SDL_JoystickInstanceID(joystick);
    if (SDL_JoystickSetVirtualAxis(joystick, 4, -32768) != 0 ||
        SDL_JoystickSetVirtualAxis(joystick, 5, -32768) != 0) return NULL;
    return joystick;
}

static int apply_command(const char *line, SDL_JoystickID *instance) {
    char command[16], extra;
    int element = -1, value = 0;
    int fields = sscanf(line, "%15s %d %d %c", command, &element, &value, &extra);
    int result = -1;
    SDL_LockJoysticks();
    SDL_Joystick *joystick = ensure_controller(instance);
    if (joystick && fields == 3 && strcmp(command, "button") == 0 &&
        element >= 0 && element < 15 && (value == 0 || value == 1)) {
        result = SDL_JoystickSetVirtualButton(joystick, element, (Uint8)value);
    } else if (joystick && fields == 3 && strcmp(command, "axis") == 0 &&
               element >= 0 && element < 6 && value >= -32768 && value <= 32767) {
        result = SDL_JoystickSetVirtualAxis(joystick, element, (Sint16)value);
    } else if (joystick && fields == 2 && strcmp(command, "tap") == 0 &&
               element >= 0 && element < 15) {
        int down = SDL_JoystickSetVirtualButton(joystick, element, 1);
        SDL_UnlockJoysticks();
        usleep(300000);
        SDL_LockJoysticks();
        joystick = SDL_JoystickFromInstanceID(*instance);
        int up = joystick ? SDL_JoystickSetVirtualButton(joystick, element, 0) : -1;
        result = down == 0 && up == 0 ? 0 : -1;
    } else if (joystick && fields == 1 && strcmp(command, "state") == 0) {
        result = SDL_JoystickGetAttached(joystick) ? 0 : -1;
    }
    SDL_UnlockJoysticks();
    return result;
}

static void *controller_worker(void *unused) {
    (void)unused;
    const char *directory = getenv("FENRIR_NATIVE_DIR");
    if (!directory) return NULL;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/controller.sock", directory)
        >= (int)sizeof(address.sun_path)) {
        fprintf(stderr, "Native controller socket path is too long\n");
        return NULL;
    }
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return NULL;
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listener, 4) != 0) {
        fprintf(stderr, "Native controller socket failed: %s\n", strerror(errno));
        close(listener);
        return NULL;
    }
    if (chmod(address.sun_path, 0600) != 0) {
        close(listener);
        unlink(address.sun_path);
        return NULL;
    }
    SDL_JoystickID instance = -1;
    struct pollfd input = {.fd = listener, .events = POLLIN};
    for (;;) {
        SDL_LockJoysticks();
        ensure_controller(&instance);
        SDL_UnlockJoysticks();
        if (poll(&input, 1, 100) <= 0) continue;
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) continue;
        int no_sigpipe = 1;
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
        struct timeval timeout = {.tv_sec = 5};
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        FILE *stream = fdopen(connection, "r+");
        if (!stream) {
            close(connection);
            continue;
        }
        setvbuf(stream, NULL, _IONBF, 0);
        char line[128];
        while (fgets(line, sizeof(line), stream)) {
            int result = strchr(line, '\n') ? apply_command(line, &instance) : -1;
            if (fprintf(stream, "{\"acknowledged\":%s}\n", result == 0 ? "true" : "false") < 0) break;
        }
        fclose(stream);
    }
    return NULL;
}

__attribute__((constructor)) static void inject_controller(void) {
    pthread_t thread;
    int result = pthread_create(&thread, NULL, controller_worker, NULL);
    if (result == 0) pthread_detach(thread);
    else fprintf(stderr, "Native controller thread failed: %s\n", strerror(result));
}
