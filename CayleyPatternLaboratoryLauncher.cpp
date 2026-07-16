#define UNICODE
#define _UNICODE
#include <windows.h>
#include <filesystem>
#include <string>
#include <stdexcept>
#include <vector>

namespace {

std::wstring quote_windows_argument(const std::wstring& value) {
    if (!value.empty() && value.find_first_of(L" \t\n\v\"") == std::wstring::npos)
        return value;

    std::wstring out;
    out.push_back(L'"');
    std::size_t backslashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') {
            ++backslashes;
            continue;
        }
        if (ch == L'"') {
            out.append(backslashes * 2 + 1, L'\\');
            out.push_back(L'"');
            backslashes = 0;
            continue;
        }
        out.append(backslashes, L'\\');
        backslashes = 0;
        out.push_back(ch);
    }
    out.append(backslashes * 2, L'\\');
    out.push_back(L'"');
    return out;
}

std::filesystem::path executable_directory() {
    std::vector<wchar_t> buffer(1024);
    for (;;) {
        const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                               static_cast<DWORD>(buffer.size()));
        if (length == 0)
            throw std::runtime_error("GetModuleFileNameW failed");
        if (length < buffer.size() - 1)
            return std::filesystem::path(std::wstring(buffer.data(), length)).parent_path();
        buffer.resize(buffer.size() * 2);
    }
}

void show_error(const std::wstring& message) {
    MessageBoxW(nullptr, message.c_str(), L"Cayley Pattern Laboratory",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        const std::filesystem::path directory = executable_directory();
        const std::filesystem::path script = directory / L"CayleyPatternLaboratory.ps1";
        if (!std::filesystem::exists(script)) {
            show_error(L"The interface script is missing:\n\n" + script.wstring() +
                       L"\n\nExtract all files from the release ZIP into one folder.");
            return 2;
        }

        const std::wstring powershell = L"powershell.exe";
        std::wstring command = quote_windows_argument(powershell)
            + L" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "
            + quote_windows_argument(script.wstring());
        std::vector<wchar_t> mutable_command(command.begin(), command.end());
        mutable_command.push_back(L'\0');

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        const std::wstring working_directory = directory.wstring();

        const BOOL created = CreateProcessW(
            nullptr,
            mutable_command.data(),
            nullptr,
            nullptr,
            FALSE,
            CREATE_NO_WINDOW,
            nullptr,
            working_directory.c_str(),
            &startup,
            &process
        );
        if (!created) {
            const DWORD error = GetLastError();
            show_error(L"Windows could not start the graphical interface.\n\nError code: "
                       + std::to_wstring(error)
                       + L"\n\nYou can use Launch_Cayley_Pattern_Laboratory.bat as a diagnostic fallback.");
            return 3;
        }

        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return 0;
    }
    catch (const std::exception&) {
        show_error(L"The graphical interface could not be started. Extract the complete package "
                   L"to a local Windows folder and try again.");
        return 1;
    }
}
