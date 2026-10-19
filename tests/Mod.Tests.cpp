// SPDX-License-Identifier: MIT
#include <windhawk_api.h>

#include "../src/console-default-terminal.wh.cpp"

#include <cstdio>
#include <shellapi.h>
#include <string>
#include <vector>

namespace
{
unsigned g_checks = 0;
unsigned g_failures = 0;
FILE *g_report = stdout;

void Check(bool result, const char *name)
{
    ++g_checks;
    if (!result)
        ++g_failures;
    fprintf(g_report, "%s %s\n", result ? "PASS" : "FAIL", name);
    fflush(g_report);
}

std::vector<BYTE> MakeEa(const char *name = "server")
{
    TerminalHandoff::EaHeader header{};
    header.nameLength = static_cast<UCHAR>(strlen(name));
    header.valueLength = sizeof(TerminalHandoff::ConsoleServerMessage);
    std::vector<BYTE> bytes(sizeof(header) + header.nameLength + 1 + header.valueLength);
    memcpy(bytes.data(), &header, sizeof(header));
    memcpy(bytes.data() + sizeof(header), name, header.nameLength + 1);
    TerminalHandoff::ConsoleServerMessage message{};
    message.windowVisible = TRUE;
    memcpy(bytes.data() + sizeof(header) + header.nameLength + 1, &message, sizeof(message));
    return bytes;
}

void PutMessage(std::vector<BYTE> &bytes, const TerminalHandoff::ConsoleServerMessage &message)
{
    memcpy(bytes.data() + sizeof(TerminalHandoff::EaHeader) + 7, &message, sizeof(message));
}

void TestParser()
{
    size_t offset = 0;
    auto bytes = MakeEa();
    const auto original = bytes;
    Check(TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "accepts an unaligned ConDrv server message");
    Check(offset == sizeof(TerminalHandoff::EaHeader) + 7 +
                        offsetof(TerminalHandoff::ConsoleServerMessage, consoleApp),
          "locates the protocol field");
    Check(bytes == original, "parser leaves caller storage unchanged");
    Check(!TerminalHandoff::FindConsoleAppOffset(nullptr, 100, offset), "rejects null buffers");
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), 7, offset), "rejects short headers");
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size() - 1, offset),
          "rejects truncated payloads");
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), 65537, offset),
          "rejects oversized EA buffers before reading them");
    bytes = MakeEa("attach");
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "does not redirect AttachConsole requests");
    bytes = MakeEa("other!");
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "ignores unrelated EAs");

    TerminalHandoff::ConsoleServerMessage message{};
    message.windowVisible = TRUE;
    for (WORD show : {SW_HIDE, SW_SHOWMINIMIZED, SW_MINIMIZE, SW_SHOWMINNOACTIVE, SW_FORCEMINIMIZE})
    {
        bytes = MakeEa();
        message.startupFlags = STARTF_USESHOWWINDOW;
        message.showWindow = show;
        PutMessage(bytes, message);
        Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
              "preserves hidden and minimized startup requests");
    }
    message = {};
    bytes = MakeEa();
    PutMessage(bytes, message);
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "preserves windowless requests");
    message.windowVisible = TRUE;
    message.consoleApp = TRUE;
    PutMessage(bytes, message);
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "leaves existing console-app flags alone");
    message.consoleApp = FALSE;
    message.titleLength = 1;
    PutMessage(bytes, message);
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects odd UTF-16 lengths");
    message.titleLength = sizeof(message.title);
    PutMessage(bytes, message);
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects out-of-bounds strings");
    message.titleLength = 0;
    message.title[0] = L'x';
    PutMessage(bytes, message);
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects unterminated strings");
    bytes = MakeEa();
    bytes[sizeof(TerminalHandoff::EaHeader) + 6] = 'x';
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects unterminated EA names");
    bytes = MakeEa();
    bytes[6] = 0;
    bytes[7] = 0;
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects unrecognized protocol sizes");

    bytes = MakeEa();
    const size_t aligned = (bytes.size() + 3) & ~size_t{3};
    const ULONG next = static_cast<ULONG>(aligned);
    memcpy(bytes.data(), &next, sizeof(next));
    bytes.resize(aligned);
    auto tail = MakeEa("other!");
    bytes.insert(bytes.end(), tail.begin(), tail.end());
    Check(TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "supports additional aligned EAs");
    tail = MakeEa();
    bytes.resize(aligned);
    bytes.insert(bytes.end(), tail.begin(), tail.end());
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects duplicate server EAs");
    tail = MakeEa("attach");
    bytes.resize(aligned);
    bytes.insert(bytes.end(), tail.begin(), tail.end());
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects attach EAs anywhere in the chain");
    const ULONG malformed = 1;
    memcpy(bytes.data(), &malformed, sizeof(malformed));
    Check(!TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), offset),
          "rejects malformed chain offsets");
}

const void *g_sourceBuffer;
size_t g_testFlagOffset;
bool g_cloned;
BYTE g_forwardedFlag;
DWORD g_incomingError;

NTSTATUS NTAPI CaptureCreate(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
                             PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID ea, ULONG)
{
    g_incomingError = GetLastError();
    g_cloned = ea != g_sourceBuffer;
    g_forwardedFlag = static_cast<const BYTE *>(ea)[g_testFlagOffset];
    SetLastError(0x4321);
    return static_cast<NTSTATUS>(0xC0000022);
}

void TestForwarding()
{
    auto bytes = MakeEa();
    const auto before = bytes;
    TerminalHandoff::FindConsoleAppOffset(bytes.data(), bytes.size(), g_testFlagOffset);
    g_sourceBuffer = bytes.data();
    g_createFile = CaptureCreate;
    WCHAR path[] = L"\\Device\\ConDrv\\Connect";
    UNICODE_STRING name{sizeof(path) - sizeof(WCHAR), sizeof(path), path};
    OBJECT_ATTRIBUTES attributes{};
    attributes.Length = sizeof(attributes);
    attributes.ObjectName = &name;
    CreateFileHook(nullptr, 0, &attributes, nullptr, nullptr, 0, 0, 0, 0, bytes.data(),
                   static_cast<ULONG>(bytes.size()));
    Check(!g_cloned && g_forwardedFlag == FALSE, "passes requests outside allocation through");
    {
        AllocationScope scope;
        SetLastError(0x1234);
        const auto status = CreateFileHook(nullptr, 0, &attributes, nullptr, nullptr, 0, 0, 0, 0,
                                           bytes.data(), static_cast<ULONG>(bytes.size()));
        const auto error = GetLastError();
        Check(g_cloned && g_forwardedFlag == TRUE, "forwards a corrected copy during allocation");
        Check(bytes == before, "hook preserves the complete original request buffer");
        Check(g_incomingError == 0x1234 && error == 0x4321,
              "preserves caller and native last-error values");
        Check(status == static_cast<NTSTATUS>(0xC0000022), "preserves the native return status");
        WCHAR other[] = L"\\Device\\Other\\Connect";
        name = {sizeof(other) - sizeof(WCHAR), sizeof(other), other};
        CreateFileHook(nullptr, 0, &attributes, nullptr, nullptr, 0, 0, 0, 0, bytes.data(),
                       static_cast<ULONG>(bytes.size()));
        Check(!g_cloned && g_forwardedFlag == FALSE, "does not modify other device requests");
    }
}

CreateFileFunction g_nativeCreate;
size_t g_observedOffset;
bool g_observe = false;
unsigned g_rewritten = 0;
std::wstring g_parentName;

NTSTATUS NTAPI ForwardCreate(PHANDLE handle, ACCESS_MASK access, POBJECT_ATTRIBUTES attributes,
                             PIO_STATUS_BLOCK ioStatus, PLARGE_INTEGER allocationSize, ULONG flags,
                             ULONG sharing, ULONG disposition, ULONG options, PVOID ea,
                             ULONG length)
{
    if (g_observe && ea && g_observedOffset < length &&
        static_cast<const BYTE *>(ea)[g_observedOffset] == TRUE)
        ++g_rewritten;
    return g_nativeCreate(handle, access, attributes, ioStatus, allocationSize, flags, sharing,
                          disposition, options, ea, length);
}

NTSTATUS NTAPI ObserveCreate(PHANDLE handle, ACCESS_MASK access, POBJECT_ATTRIBUTES attributes,
                             PIO_STATUS_BLOCK ioStatus, PLARGE_INTEGER allocationSize, ULONG flags,
                             ULONG sharing, ULONG disposition, ULONG options, PVOID ea,
                             ULONG length)
{
    g_observe =
        g_allocationDepth && TerminalHandoff::FindConsoleAppOffset(ea, length, g_observedOffset);
    if (g_observe && attributes && attributes->RootDirectory)
    {
        BYTE buffer[2048]{};
        ULONG returned = 0;
        if (g_queryObject(attributes->RootDirectory, ObjectNameInformation, buffer, sizeof(buffer),
                          &returned) >= 0)
        {
            auto name = reinterpret_cast<UNICODE_STRING *>(buffer);
            g_parentName.assign(name->Buffer, name->Length / sizeof(WCHAR));
        }
    }
    const auto result = CreateFileHook(handle, access, attributes, ioStatus, allocationSize, flags,
                                       sharing, disposition, options, ea, length);
    g_observe = false;
    return result;
}

void **FindNativeCreateImport()
{
    auto base = reinterpret_cast<BYTE *>(GetModuleHandleW(L"kernelbase.dll"));
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    auto imports = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR *>(
        base + nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
    for (; imports->Name; ++imports)
    {
        if (_stricmp(reinterpret_cast<const char *>(base + imports->Name), "ntdll.dll"))
            continue;
        auto names = reinterpret_cast<IMAGE_THUNK_DATA *>(base + imports->OriginalFirstThunk);
        auto slots = reinterpret_cast<IMAGE_THUNK_DATA *>(base + imports->FirstThunk);
        for (; names->u1.AddressOfData; ++names, ++slots)
        {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))
                continue;
            auto name = reinterpret_cast<IMAGE_IMPORT_BY_NAME *>(base + names->u1.AddressOfData);
            if (!strcmp(reinterpret_cast<const char *>(name->Name), "NtCreateFile"))
                return reinterpret_cast<void **>(&slots->u1.Function);
        }
    }
    return nullptr;
}

bool SetImport(void **slot, void *value)
{
    DWORD protection;
    if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &protection))
        return false;
    *slot = value;
    DWORD ignored;
    return VirtualProtect(slot, sizeof(*slot), protection, &ignored) != FALSE;
}

void TestNativeConnection()
{
    Check(IsInteractiveGuiProcess(), "runs as an interactive GUI application");
    auto kernel = GetModuleHandleW(L"kernelbase.dll");
    auto native = GetModuleHandleW(L"ntdll.dll");
    g_allocate = reinterpret_cast<AllocateFunction>(GetProcAddress(kernel, "AllocConsole"));
    g_allocateWithOptions = reinterpret_cast<AllocateWithOptionsFunction>(
        GetProcAddress(kernel, "AllocConsoleWithOptions"));
    g_queryObject = reinterpret_cast<QueryObjectFunction>(GetProcAddress(native, "NtQueryObject"));
    void **slot = FindNativeCreateImport();
    Check(slot && g_allocate && g_queryObject, "resolves native APIs without symbols or offsets");
    if (!slot)
        return;
    void *previous = *slot;
    g_nativeCreate = reinterpret_cast<CreateFileFunction>(previous);
    g_createFile = ForwardCreate;
    Check(SetImport(slot, reinterpret_cast<void *>(ObserveCreate)),
          "installs a test-only import hook in the isolated process");
    const BOOL allocated = AllocateHook();
    const DWORD error = GetLastError();
    fprintf(g_report, "Native allocation: %u; error: %lu; rewrites: %u; parent: %ls\n", allocated,
            error, g_rewritten, g_parentName.c_str());
    Check(allocated != FALSE && GetConsoleWindow() != nullptr,
          "native console allocation succeeds");
    Check(g_rewritten == 1, "native ConDrv request reaches the kernel with ConsoleApp enabled");
    Check(g_allocationDepth == 0, "allocation scope is restored");
    if (allocated)
        FreeConsole();
    if (g_allocateWithOptions)
    {
        struct Options
        {
            DWORD mode;
            BOOL useShowWindow;
            WORD showWindow;
        } options{2, FALSE, 0};
        DWORD result = 0;
        const auto before = g_rewritten;
        const auto status = AllocateWithOptionsHook(&options, &result);
        Check(SUCCEEDED(status), "windowless allocation succeeds");
        Check(g_rewritten == before, "windowless native requests are not rewritten");
        FreeConsole();
    }
    Check(SetImport(slot, previous), "restores the isolated process import table");
}
} // namespace

int wmain(int argc, wchar_t **argv)
{
    if (argc > 1)
    {
        g_report = _wfopen(argv[1], L"w");
        if (!g_report)
            return 2;
    }
    TestParser();
    TestForwarding();
    TestNativeConnection();
    fprintf(g_report, "Checks: %u; failures: %u\n", g_checks, g_failures);
    if (g_report != stdout)
        fclose(g_report);
    return g_failures ? 1 : 0;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    int argc = 0;
    auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv)
        return 2;
    const int result = wmain(argc, argv);
    LocalFree(argv);
    return result;
}
