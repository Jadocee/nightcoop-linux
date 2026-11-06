/* SPDX-License-Identifier: MIT
 *
 * Stand-in for Cyberpunk2077.exe. It carries the game's version resource (built per
 * patch by build.sh) and imports winmm.dll like the game does, so RED4ext's loader in
 * bin/x64/winmm.dll is mapped at start-up whenever Wine prefers the native copy, and
 * RED4ext treats the process as the game. It then writes stub-report.txt next to itself:
 * which winmm.dll, RED4ext.dll and C++ runtime were loaded, and whether each is Wine's
 * built-in copy or a native file. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static FILE *out;

static int is_builtin(HMODULE m) { return memcmp((const char *)m + 0x40, "Wine builtin DLL", 16) == 0; }

static void report(const wchar_t *name)
{
    HMODULE m = GetModuleHandleW(name);
    wchar_t path[MAX_PATH] = L"";
    if (m) GetModuleFileNameW(m, path, MAX_PATH);
    fwprintf(out, L"  %-20ls %ls%ls\n", name, m ? path : L"(not loaded)",
             m ? (is_builtin(m) ? L"  [wine builtin]" : L"  [native]") : L"");
}

int main(void)
{
    wchar_t self[MAX_PATH], *slash;
    timeBeginPeriod(1);
    GetModuleFileNameW(NULL, self, MAX_PATH);
    if ((slash = wcsrchr(self, L'\\'))) wcscpy(slash + 1, L"stub-report.txt");
    out = _wfopen(self, L"w");
    if (!out) out = stdout;
    fwprintf(out, L"stand-in Cyberpunk2077.exe\n");
    report(L"winmm.dll");
    report(L"RED4ext.dll");
    report(L"msvcp140.dll");
    report(L"vcruntime140.dll");
    report(L"vcruntime140_1.dll");
    fclose(out);
    timeEndPeriod(1);
    return 0;
}
