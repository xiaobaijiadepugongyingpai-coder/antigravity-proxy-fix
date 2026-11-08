/*
 * agy-shim: 只给 agy 注入代理环境变量，其它程序完全不受影响。
 *
 * 行为：
 *   1. 如果进程环境里已经存在 HTTP_PROXY / HTTPS_PROXY（用户自己设了），原样放行。
 *   2. 否则探测本机代理端口，通的话注入给子进程。
 *      优先用 AGY_PROXY 环境变量，其次 7897（Clash Verge），再其次 7890（Clash for Windows）。
 *   3. 一个都探不通就不注入，让 agy 保持原生行为。
 *   4. 用真实路径 %LOCALAPPDATA%\agy\bin\agy.exe 启动，参数原样透传，退出码原样返回。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int probe_port(unsigned short port)
{
    SOCKET s;
    struct sockaddr_in a;
    int ok;

    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET)
        return 0;

    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");

    ok = (connect(s, (struct sockaddr *)&a, sizeof a) == 0);
    closesocket(s);
    return ok;
}

static unsigned short port_of(const wchar_t *url)
{
    const wchar_t *colon = wcsrchr(url, L':');
    if (!colon)
        return 0;
    return (unsigned short)wcstoul(colon + 1, NULL, 10);
}

static void maybe_set_proxy(void)
{
    const wchar_t *cands[4];
    wchar_t custom[512];
    int n = 0, i;
    const wchar_t *chosen = NULL;
    DWORD cl;

    /* 用户已经自己配了，不插手。
     * 注意：Go 的 ProxyFromEnvironment 在 HTTPS_PROXY 未设置时会回退到
     * HTTP_PROXY，所以只设 HTTP_PROXY 也是有效配置，同样必须尊重。 */
    if (GetEnvironmentVariableW(L"HTTPS_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"https_proxy", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"HTTP_PROXY", NULL, 0) != 0 ||
        GetEnvironmentVariableW(L"http_proxy", NULL, 0) != 0)
        return;

    cl = GetEnvironmentVariableW(L"AGY_PROXY", custom, 512);
    if (cl > 0 && cl < 512)
        cands[n++] = custom;

    cands[n++] = L"http://127.0.0.1:7897"; /* Clash Verge mixed-port */
    cands[n++] = L"http://127.0.0.1:7890"; /* Clash for Windows */

    for (i = 0; i < n; i++) {
        unsigned short p = port_of(cands[i]);
        if (p && probe_port(p)) {
            chosen = cands[i];
            break;
        }
    }

    if (!chosen)
        return;

    SetEnvironmentVariableW(L"HTTPS_PROXY", chosen);
    SetEnvironmentVariableW(L"HTTP_PROXY", chosen);

    if (GetEnvironmentVariableW(L"NO_PROXY", NULL, 0) == 0 &&
        GetEnvironmentVariableW(L"no_proxy", NULL, 0) == 0)
        SetEnvironmentVariableW(L"NO_PROXY", L"localhost,127.0.0.1,::1");
}

int main(void)
{
    wchar_t self[MAX_PATH];
    wchar_t base[MAX_PATH];
    wchar_t real[MAX_PATH];
    wchar_t *slash;
    const wchar_t *cmdline, *rest;
    wchar_t *full;
    size_t need;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    WSADATA wsa;

    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) {
        fwprintf(stderr, L"agy-shim: GetModuleFileNameW failed\n");
        return 1;
    }

    wcsncpy(base, self, MAX_PATH - 1);
    base[MAX_PATH - 1] = 0;
    slash = wcsrchr(base, L'\\');
    if (slash)
        *slash = 0; /* ...\agy\shim */

    /* 真实程序位置，按顺序尝试：
     *   1. %AGY_REAL_EXE% 显式覆盖
     *   2. <shim 目录>\bin\agy.exe
     *   3. <shim 目录>\..\bin\agy.exe  （shim 放在 agy\shim\ 时走这条）
     *   4. <shim 目录>\agy-real.exe
     */
    real[0] = 0;
    {
        wchar_t probe[MAX_PATH];
        DWORD cl = GetEnvironmentVariableW(L"AGY_REAL_EXE", probe, MAX_PATH);
        if (cl > 0 && cl < MAX_PATH && GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
            wcsncpy(real, probe, MAX_PATH - 1);

        if (!real[0]) {
            _snwprintf(probe, MAX_PATH, L"%s\\bin\\agy.exe", base);
            probe[MAX_PATH - 1] = 0;
            if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                wcsncpy(real, probe, MAX_PATH - 1);
        }
        if (!real[0]) {
            _snwprintf(probe, MAX_PATH, L"%s\\..\\bin\\agy.exe", base);
            probe[MAX_PATH - 1] = 0;
            if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                wcsncpy(real, probe, MAX_PATH - 1);
        }
        if (!real[0]) {
            _snwprintf(probe, MAX_PATH, L"%s\\agy-real.exe", base);
            probe[MAX_PATH - 1] = 0;
            if (GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
                wcsncpy(real, probe, MAX_PATH - 1);
        }
    }
    real[MAX_PATH - 1] = 0;

    if (!real[0]) {
        fwprintf(stderr, L"agy-shim: cannot locate real agy.exe near %s\n", base);
        return 1;
    }

    if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
        maybe_set_proxy();
        WSACleanup();
    }

    cmdline = GetCommandLineW();
    rest = cmdline;
    if (*rest == L'"') {
        rest++;
        while (*rest && *rest != L'"')
            rest++;
        if (*rest == L'"')
            rest++;
    } else {
        while (*rest && *rest != L' ' && *rest != L'\t')
            rest++;
    }

    need = wcslen(real) + wcslen(rest) + 8;
    full = (wchar_t *)malloc(need * sizeof(wchar_t));
    if (!full)
        return 1;
    _snwprintf(full, need, L"\"%s\"%s", real, rest);

    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    memset(&pi, 0, sizeof pi);

    if (!CreateProcessW(NULL, full, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fwprintf(stderr, L"agy-shim: CreateProcessW failed (%lu)\n", GetLastError());
        free(full);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(full);
    return (int)code;
}
