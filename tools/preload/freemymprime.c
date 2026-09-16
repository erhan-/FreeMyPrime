/*
 * freemymprime.so - LD_PRELOAD payload for Denon DJ / Engine OS devices.
 *
 * Installed as /data/ssh/freemymprime.so and referenced from
 * /etc/ld.so.preload (which lives in the /etc overlay upper, under /data).
 *
 * glibc reads /etc/ld.so.preload when any dynamically linked process starts.
 * Engine is started by engine.service well after the /etc overlay is mounted,
 * so this constructor runs as root without depending on systemd scanning the
 * overlay for new units.
 *
 * It runs /data/ssh/setup.sh exactly once (O_EXCL marker file) and detaches.
 * Only GLIBC_2.4 symbols are used so it loads on the device's older glibc.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void note(const char *s)
{
    int fd = open("/data/ssh/preload.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        ssize_t r = write(fd, s, strlen(s));
        r = write(fd, "\n", 1);
        (void)r;
        close(fd);
    }
}

__attribute__((constructor))
static void freemymprime_init(void)
{
    if (getenv("FREEMYPRIME_PRELOADED"))
        return;
    setenv("FREEMYPRIME_PRELOADED", "1", 1);

    /* Run setup.sh once per boot. Best-effort marker in /run (tmpfs); if it
     * cannot be created we still proceed, and we only skip when it exists. */
    int fd = open("/run/freemymprime.started", O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd >= 0) {
        close(fd);
    } else if (access("/run/freemymprime.started", F_OK) == 0) {
        return; /* already ran this boot */
    }

    note("preload constructor ran");

    pid_t p = fork();
    if (p == 0) {
        setsid();
        execl("/data/ssh/setup.sh", "setup.sh", (char *)0);
        _exit(127);
    }
    note(p > 0 ? "forked setup.sh" : "fork failed");
}
