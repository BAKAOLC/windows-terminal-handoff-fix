// ==WindhawkMod==
// @id              console-default-terminal
// @name            Default Terminal Handoff Fix
// @description     Fix default terminal handoff for consoles allocated by GUI applications.
// @version         1.0.0
// @include         *
// @exclude         windhawk.exe
// @exclude         windhawk-x64-helper.exe
// @exclude         conhost.exe
// @exclude         OpenConsole.exe
// @exclude         WindowsTerminal.exe
// @compilerOptions -luser32
// ==/WindhawkMod==

// SPDX-License-Identifier: MIT

#include <windows.h>
#include <winternl.h>

#include <cstddef>
#include <cstring>

namespace TerminalHandoff
{
// Wire layout adapted from microsoft/terminal, dep/Console/conmsgl1.h (MIT).
// Copyright (c) Microsoft Corporation.
// These fixed-width fields are identical for x86 and x64 clients.
struct ConsoleServerMessage
{
    ULONG iconId;
    ULONG hotKey;
    ULONG startupFlags;
    USHORT fillAttribute;
    USHORT showWindow;
    COORD screenBufferSize;
    COORD windowSize;
    COORD windowOrigin;
    ULONG processGroupId;
    BOOLEAN consoleApp;
    BOOLEAN windowVisible;
    USHORT titleLength;
    WCHAR title[MAX_PATH + 1];
    USHORT applicationNameLength;
    WCHAR applicationName[128];
    USHORT currentDirectoryLength;
    WCHAR currentDirectory[MAX_PATH + 1];
};

static_assert(sizeof(ConsoleServerMessage) == 0x53c);
static_assert(offsetof(ConsoleServerMessage, consoleApp) == 0x20);

// FILE_FULL_EA_INFORMATION's fixed header, without its variable-length name.
struct EaHeader
{
    ULONG nextEntryOffset;
    UCHAR flags;
    UCHAR nameLength;
    USHORT valueLength;
};
static_assert(sizeof(EaHeader) == 8);

template <size_t N> inline bool ValidString(const WCHAR (&text)[N], USHORT byteLength)
{
    return byteLength % sizeof(WCHAR) == 0 && byteLength < sizeof(text) &&
           text[byteLength / sizeof(WCHAR)] == L'\0';
}

inline bool EligibleMessage(const ConsoleServerMessage &message)
{
    if (message.consoleApp != FALSE || message.windowVisible != TRUE ||
        !ValidString(message.title, message.titleLength) ||
        !ValidString(message.applicationName, message.applicationNameLength) ||
        !ValidString(message.currentDirectory, message.currentDirectoryLength))
        return false;

    if (message.startupFlags & STARTF_USESHOWWINDOW)
    {
        switch (message.showWindow)
        {
        case SW_HIDE:
        case SW_SHOWMINIMIZED:
        case SW_MINIMIZE:
        case SW_SHOWMINNOACTIVE:
        case SW_FORCEMINIMIZE:
            return false;
        }
    }
    return true;
}

// Parse the complete EA chain before returning an offset. Never dereference an
// unaligned message or mutate the caller's buffer, even on a malformed request.
inline bool FindConsoleAppOffset(const void *buffer, size_t length, size_t &flagOffset)
{
    if (!buffer || length < sizeof(EaHeader) || length > 65536)
        return false;
    const auto bytes = static_cast<const BYTE *>(buffer);
    size_t cursor = 0;
    bool found = false;
    size_t candidate = 0;
    while (length - cursor >= sizeof(EaHeader))
    {
        EaHeader header;
        memcpy(&header, bytes + cursor, sizeof(header));
        const size_t valueOffset = sizeof(header) + header.nameLength + 1;
        const size_t entryLength = valueOffset + header.valueLength;
        if (entryLength > length - cursor ||
            bytes[cursor + sizeof(header) + header.nameLength] != '\0')
            return false;
        const auto name = bytes + cursor + sizeof(header);
        if (header.nameLength == 6 && !memcmp(name, "attach", 6))
            return false;
        if (header.nameLength == 6 && !memcmp(name, "server", 6))
        {
            if (found || header.flags || header.valueLength != sizeof(ConsoleServerMessage))
                return false;
            ConsoleServerMessage message;
            memcpy(&message, bytes + cursor + valueOffset, sizeof(message));
            if (!EligibleMessage(message))
                return false;
            candidate = cursor + valueOffset + offsetof(ConsoleServerMessage, consoleApp);
            found = true;
        }
        if (!header.nextEntryOffset)
        {
            // Native EA lists may include up to three bytes of alignment padding.
            if (length - cursor - entryLength > 3)
                return false;
            if (found)
                flagOffset = candidate;
            return found;
        }
        if (header.nextEntryOffset % 4 || header.nextEntryOffset < entryLength ||
            header.nextEntryOffset > length - cursor)
            return false;
        cursor += header.nextEntryOffset;
    }
    return false;
}
} // namespace TerminalHandoff

namespace
{
using CreateFileFunction = NTSTATUS(NTAPI *)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES,
                                             PIO_STATUS_BLOCK, PLARGE_INTEGER, ULONG, ULONG, ULONG,
                                             ULONG, PVOID, ULONG);
using AllocateFunction = BOOL(WINAPI *)();
using AllocateWithOptionsFunction = HRESULT(WINAPI *)(const void *, void *);
using QueryObjectFunction = NTSTATUS(NTAPI *)(HANDLE, OBJECT_INFORMATION_CLASS, PVOID, ULONG,
                                              PULONG);

CreateFileFunction g_createFile;
AllocateFunction g_allocate;
AllocateWithOptionsFunction g_allocateWithOptions;
QueryObjectFunction g_queryObject;
thread_local unsigned g_allocationDepth = 0;

class AllocationScope
{
  public:
    AllocationScope()
    {
        ++g_allocationDepth;
    }
    ~AllocationScope()
    {
        --g_allocationDepth;
    }
    AllocationScope(const AllocationScope &) = delete;
    AllocationScope &operator=(const AllocationScope &) = delete;
};

template <size_t N> bool EqualName(const UNICODE_STRING &name, const WCHAR (&expected)[N])
{
    return name.Buffer && name.Length == (N - 1) * sizeof(WCHAR) &&
           CompareStringOrdinal(name.Buffer, name.Length / sizeof(WCHAR), expected, N - 1, TRUE) ==
               CSTR_EQUAL;
}

bool IsConsoleConnection(const OBJECT_ATTRIBUTES *attributes)
{
    if (!attributes || attributes->Length != sizeof(*attributes) || !attributes->ObjectName)
        return false;
    if (!attributes->RootDirectory)
        return EqualName(*attributes->ObjectName, L"\\Device\\ConDrv\\Connect");
    if (!EqualName(*attributes->ObjectName, L"\\Connect"))
        return false;

    // A relative name is accepted only if its parent is actually a ConDrv server.
    struct ObjectNameBuffer
    {
        UNICODE_STRING name;
        WCHAR text[512];
    } buffer{};
    ULONG returned = 0;
    const auto status = g_queryObject(attributes->RootDirectory, ObjectNameInformation, &buffer,
                                      sizeof(buffer), &returned);
    if (status < 0 || buffer.name.Length > sizeof(buffer.text))
        return false;
    return EqualName(buffer.name, L"\\Device\\ConDrv") ||
           EqualName(buffer.name, L"\\Device\\ConDrv\\Server");
}

NTSTATUS NTAPI CreateFileHook(PHANDLE handle, ACCESS_MASK access, POBJECT_ATTRIBUTES attributes,
                              PIO_STATUS_BLOCK ioStatus, PLARGE_INTEGER allocationSize,
                              ULONG fileFlags, ULONG sharing, ULONG disposition, ULONG options,
                              PVOID ea, ULONG eaLength)
{
    if (!g_allocationDepth || !ea || eaLength < sizeof(TerminalHandoff::EaHeader))
        return g_createFile(handle, access, attributes, ioStatus, allocationSize, fileFlags,
                            sharing, disposition, options, ea, eaLength);

    const DWORD lastError = GetLastError();
    size_t offset = 0;
    BYTE *copy = nullptr;
    if (IsConsoleConnection(attributes) &&
        TerminalHandoff::FindConsoleAppOffset(ea, eaLength, offset))
    {
        copy = static_cast<BYTE *>(HeapAlloc(GetProcessHeap(), 0, eaLength));
        if (copy)
        {
            memcpy(copy, ea, eaLength);
            copy[offset] = TRUE;
        }
    }
    SetLastError(lastError);
    const auto status =
        g_createFile(handle, access, attributes, ioStatus, allocationSize, fileFlags, sharing,
                     disposition, options, copy ? copy : ea, eaLength);
    const DWORD resultError = GetLastError();
    if (copy)
        HeapFree(GetProcessHeap(), 0, copy);
    SetLastError(resultError);
    return status;
}

BOOL WINAPI AllocateHook()
{
    AllocationScope scope;
    return g_allocate();
}

HRESULT WINAPI AllocateWithOptionsHook(const void *options, void *result)
{
    // Visibility is checked in the outgoing message, after Windows has resolved
    // defaults and inherited settings. Attach requests have their own EA name.
    AllocationScope scope;
    return g_allocateWithOptions(options, result);
}

bool IsInteractiveGuiProcess()
{
    DWORD session = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0)
        return false;
    USEROBJECTFLAGS station{};
    DWORD stationBytes = 0;
    if (!GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS, &station, sizeof(station),
                                   &stationBytes) ||
        !(station.dwFlags & WSF_VISIBLE))
        return false;
    const auto base = reinterpret_cast<const BYTE *>(GetModuleHandleW(nullptr));
    const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0)
        return false;
    const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
    return nt->Signature == IMAGE_NT_SIGNATURE &&
           nt->OptionalHeader.Subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI;
}
} // namespace

BOOL Wh_ModInit()
{
    if (!IsInteractiveGuiProcess())
        return FALSE;
    const auto kernel = GetModuleHandleW(L"kernelbase.dll");
    const auto native = GetModuleHandleW(L"ntdll.dll");
    if (!kernel || !native)
        return FALSE;
    const auto create = GetProcAddress(native, "NtCreateFile");
    const auto allocate = GetProcAddress(kernel, "AllocConsole");
    const auto withOptions = GetProcAddress(kernel, "AllocConsoleWithOptions");
    g_queryObject = reinterpret_cast<QueryObjectFunction>(GetProcAddress(native, "NtQueryObject"));
    if (!create || !allocate || !g_queryObject)
        return FALSE;
    if (!Wh_SetFunctionHook(reinterpret_cast<void *>(create),
                            reinterpret_cast<void *>(CreateFileHook),
                            reinterpret_cast<void **>(&g_createFile)) ||
        !Wh_SetFunctionHook(reinterpret_cast<void *>(allocate),
                            reinterpret_cast<void *>(AllocateHook),
                            reinterpret_cast<void **>(&g_allocate)))
        return FALSE;
    // Optional: this export was added in Windows 11 24H2. Earlier releases use
    // AllocConsole, so its absence must not disable the mod.
    if (withOptions && !Wh_SetFunctionHook(reinterpret_cast<void *>(withOptions),
                                           reinterpret_cast<void *>(AllocateWithOptionsHook),
                                           reinterpret_cast<void **>(&g_allocateWithOptions)))
        return FALSE;
    return TRUE;
}
