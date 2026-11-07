// ladder/cpplinux_launcher.cpp
//
// Native Linux x86_64 C++ (cpplinux / BinaryCpp) entrypoint for AI Arena.
// When a bot is registered on AI Arena with Type = "cpplinux" (C++ Linux),
// arenaclient/match/bot.py extracts <BotName>.zip, runs:
//   os.chmod(os.path.join(self.bot_directory, self.name), 0o770)
// and launches:
//   /path/to/bot_dir/<BotName> --GamePort <P> --StartPort <P> --LadderServer <H> --OpponentId <ID>
//
// This native ELF binary:
//   1. Resolves its own directory via /proc/self/exe and chdirs into it.
//   2. Ensures ./data/ exists for persistent AI Arena bot_data across matches.
//   3. Extracts racket_runtime.tar.xz (if not already unpacked) and chmods
//      racket_runtime/bin/racket to 0755.
//   4. Execs directly into the Pure-Racket Native WebSocket + Protobuf runner
//      (`racket sim/racket-sc2-ladder-main.rkt --BotName <BotName> [all original CLI flags]`)
//      when `racket_runtime/bin/racket` or `/home/antigravity/toolchains/racket/bin/racket`
//      and `sim/racket-sc2-ladder-main.rkt` are present, falling back to `python3 run.py`
//      only if the Racket binary is absent.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <libgen.h>
#include <limits.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#ifndef BOT_VARIANT_NAME
#define BOT_VARIANT_NAME "Mothman-R"
#endif

static bool file_exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

static void ensure_racket_etc_config() {
    mkdir("racket_runtime/etc", 0755);
    if (!file_exists("racket_runtime/etc/config.rktd")) {
        FILE* f = std::fopen("racket_runtime/etc/config.rktd", "w");
        if (f != nullptr) {
            std::fputs("#hash()\n", f);
            std::fclose(f);
        }
    }
}

int main(int argc, char* argv[]) {
    char exe_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len != -1) {
        exe_path[len] = '\0';
        char* dir = dirname(exe_path);
        if (dir != nullptr) {
            (void)chdir(dir);
            if (!file_exists("sim/racket-sc2-ladder-main.rkt") && !file_exists("run.py")) {
                if (file_exists("../sim/racket-sc2-ladder-main.rkt") || file_exists("../run.py")) {
                    (void)chdir("..");
                } else if (file_exists("../../sim/racket-sc2-ladder-main.rkt") || file_exists("../../run.py")) {
                    (void)chdir("../..");
                }
            }
        }
    }

    // Ensure AI Arena persistent ./data directory exists
    mkdir("data", 0770);

    // Unpack portable Debian 12 x86_64 Racket runtime if needed
    if (!file_exists("racket_runtime/bin/racket") && file_exists("racket_runtime.tar.xz")) {
        int rc = std::system("tar -xJf racket_runtime.tar.xz >/dev/null 2>&1");
        (void)rc;
    }
    if (file_exists("racket_runtime/bin/racket")) {
        chmod("racket_runtime/bin/racket", 0755);
        ensure_racket_etc_config();
    }

    // Check if user explicitly requested the legacy Python bridge via --use-python-bridge
    bool force_python_bridge = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--use-python-bridge") == 0) {
            force_python_bridge = true;
            break;
        }
    }

    // 1. Direct Pure-Racket Native WebSocket + Protobuf execution (Zero-Python Match Loop)
    if (!force_python_bridge && file_exists("sim/racket-sc2-ladder-main.rkt")) {
        const char* sys_racket = "/home/antigravity/toolchains/racket/bin/racket";
        if (file_exists("racket_runtime/bin/racket")) {
            std::vector<std::string> rk_args;
            rk_args.push_back("racket_runtime/bin/racket");
            rk_args.push_back("-X");
            rk_args.push_back("racket_runtime/collects");
            rk_args.push_back("-G");
            rk_args.push_back("racket_runtime/etc");
            rk_args.push_back("sim/racket-sc2-ladder-main.rkt");
            rk_args.push_back("--BotName");
            rk_args.push_back(BOT_VARIANT_NAME);
            for (int i = 1; i < argc; ++i) {
                if (std::strcmp(argv[i], "--native-racket") != 0) {
                    rk_args.push_back(argv[i]);
                }
            }
            std::vector<char*> rk_argv;
            rk_argv.reserve(rk_args.size() + 1);
            for (auto& s : rk_args) {
                rk_argv.push_back(const_cast<char*>(s.c_str()));
            }
            rk_argv.push_back(nullptr);
            execv("racket_runtime/bin/racket", rk_argv.data());
        } else if (file_exists(sys_racket)) {
            std::vector<std::string> rk_args;
            rk_args.push_back(sys_racket);
            rk_args.push_back("sim/racket-sc2-ladder-main.rkt");
            rk_args.push_back("--BotName");
            rk_args.push_back(BOT_VARIANT_NAME);
            for (int i = 1; i < argc; ++i) {
                if (std::strcmp(argv[i], "--native-racket") != 0) {
                    rk_args.push_back(argv[i]);
                }
            }
            std::vector<char*> rk_argv;
            rk_argv.reserve(rk_args.size() + 1);
            for (auto& s : rk_args) {
                rk_argv.push_back(const_cast<char*>(s.c_str()));
            }
            rk_argv.push_back(nullptr);
            execv(sys_racket, rk_argv.data());
        }
    }

    // 2. Fallback to Python entrypoint if Racket binary is absent
    std::vector<std::string> args_storage;
    args_storage.push_back("python3");
    args_storage.push_back("run.py");
    args_storage.push_back("--BotName");
    args_storage.push_back(BOT_VARIANT_NAME);
    for (int i = 1; i < argc; ++i) {
        args_storage.push_back(argv[i]);
    }

    std::vector<char*> exec_argv;
    exec_argv.reserve(args_storage.size() + 1);
    for (auto& s : args_storage) {
        exec_argv.push_back(const_cast<char*>(s.c_str()));
    }
    exec_argv.push_back(nullptr);

    execvp("python3", exec_argv.data());
    exec_argv[0] = const_cast<char*>("python");
    execvp("python", exec_argv.data());

    std::cerr << "[cpplinux_launcher] Failed to exec racket or python3/python for " << BOT_VARIANT_NAME << std::endl;
    return 1;
}
