/*
  PatternEngine.cpp

  Exact portable multithreaded enumeration of classical, consecutive, and vincular pattern avoidance in Cayley permutations and restricted growth functions.

  A Cayley permutation of length n and maximum k is a surjective word over
  {1,...,k}. A restricted growth function (RGF) satisfies w_1=1 and
  w_i <= 1+max(w_1,...,w_{i-1}); its maximum is its number of blocks.
  A word contains a pattern p when selected entries have the same weak/strict
  order relations (including equalities) as p. Classical patterns allow arbitrary
  subsequences; consecutive and vincular patterns impose adjacency requirements.

  The program accepts any finite collection of avoidance classes. Each class
  may have one or more forbidden Cayley patterns. It reports counts for every
  n up to a requested bound, both in total and refined by maximum k.

  Compile on Linux/macOS:
      g++ -O3 -march=native -std=c++20 -pthread \
          PatternEngine.cpp -o PatternEngine

  Compile on Windows with a C++20 compiler; no WSL is required.

  Example:
      ./PatternEngine --family cayley --max-n 11 --threads 16 \
          --classes classes.txt --output pair

  This writes pair_totals.csv and pair_by_max.csv.
*/

#include <algorithm>
#include <atomic>
#include <array>
#include <bit>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  define NOMINMAX
#  include <windows.h>
#endif

namespace portable_threads {

inline int hardware_thread_count() noexcept {
    const unsigned value = std::thread::hardware_concurrency();
    return value == 0 ? 1 : static_cast<int>(value);
}

inline int effective_thread_count(int requested, std::uint64_t task_count = 0) noexcept {
    int count = requested > 0 ? requested : hardware_thread_count();
    count = std::max(1, count);
    if (task_count > 0 && task_count < static_cast<std::uint64_t>(count))
        count = static_cast<int>(task_count);
    return std::max(1, count);
}

template <class Function>
void parallel_for_dynamic(std::uint64_t task_count, int requested_threads, Function&& function) {
    if (task_count == 0) return;
    const int worker_count = effective_thread_count(requested_threads, task_count);
    if (worker_count == 1) {
        for (std::uint64_t index = 0; index < task_count; ++index)
            function(index, 0);
        return;
    }

    std::atomic<std::uint64_t> next{0};
    std::atomic<bool> stop{false};
    std::exception_ptr first_exception;
    std::mutex exception_mutex;
    std::vector<std::thread> workers;
    workers.reserve(static_cast<std::size_t>(worker_count));

    for (int worker = 0; worker < worker_count; ++worker) {
        workers.emplace_back([&, worker] {
            try {
                while (!stop.load(std::memory_order_relaxed)) {
                    const std::uint64_t index = next.fetch_add(1, std::memory_order_relaxed);
                    if (index >= task_count) break;
                    function(index, worker);
                }
            } catch (...) {
                {
                    std::lock_guard<std::mutex> guard(exception_mutex);
                    if (!first_exception) first_exception = std::current_exception();
                }
                stop.store(true, std::memory_order_relaxed);
            }
        });
    }
    for (std::thread& worker : workers) worker.join();
    if (first_exception) std::rethrow_exception(first_exception);
}

} // namespace portable_threads

namespace cayley {

std::filesystem::path native_path(const std::string& utf8) {
#ifdef _WIN32
    if (utf8.empty()) return {};
    if (utf8.size() > static_cast<std::size_t>((std::numeric_limits<int>::max)()))
        throw std::runtime_error("file path is too long");
    const int length = static_cast<int>(utf8.size());
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                              utf8.data(), length, nullptr, 0);
    if (required <= 0) throw std::runtime_error("file path is not valid UTF-8");
    std::wstring wide(static_cast<std::size_t>(required), L'\0');
    const int written = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                             utf8.data(), length, wide.data(), required);
    if (written != required) throw std::runtime_error("could not convert a file path to UTF-16");
    return std::filesystem::path(wide);
#else
    return std::filesystem::path(utf8);
#endif
}

using Count = unsigned __int128;
using LetterMask = std::uint64_t;
using ClassMask = std::uint64_t;

constexpr int MAX_N = 24;
constexpr std::size_t MAX_CLASSES = 64;
constexpr std::uint64_t MAX_PREFIX_TASKS = 2'000'000ULL;

enum class EngineChoice {
    Auto,
    Prefix,
    Leaf
};

enum class ObjectFamily {
    Cayley,
    RGF
};

struct Options {
    int min_n = 0;
    int max_n = 10;
    int only_k = 0;                 // 0 means all k for each n
    int threads = 0;                // 0 means all available hardware threads
    int split_depth = -1;           // -1 means automatic
    EngineChoice engine = EngineChoice::Auto;
    ObjectFamily family = ObjectFamily::Cayley;
    bool quiet = false;
    bool self_test = false;
    std::string classes_file;
    std::vector<std::string> class_specs;
    std::string statistics_file;
    std::vector<std::string> statistic_specs;
    std::string output_prefix = "pattern_results";
    std::string catalog_dir;

    // Paged listing mode. Class indices are one-based on the command line.
    bool list_mode = false;
    int list_class = 0;
    int list_n = -1;
    std::uint64_t list_offset = 0;
    std::uint64_t list_limit = 100; // 0 means all remaining avoiders
    std::string list_output;

    // Inspect one word against one generalized pattern.
    bool inspect_mode = false;
    std::string inspect_word;
    std::string inspect_pattern;
    std::string inspect_output_prefix;
    std::uint64_t inspect_limit = 1000;

    // Occurrence distribution of one query pattern over one avoidance class.
    bool query_mode = false;
    int query_class = 0;
    int query_n = -1;
    std::string query_pattern;
    std::string query_output;
};

enum class PatternType {
    Classical,
    Consecutive,
    Vincular
};

enum class DetectorKind {
    Generic,
    Pattern11,
    Pattern12,
    Pattern21,
    Pattern13442,
    Pattern14233
};

struct Pattern {
    std::vector<int> values;         // 1-based ranks
    std::vector<bool> bonds;         // bonds[i]: selected positions i and i+1 must be adjacent
    PatternType type = PatternType::Classical;
    int length = 0;
    int rank = 0;                    // number of distinct letters
    int defect = 0;                  // length - rank
    DetectorKind detector = DetectorKind::Generic;
    ClassMask class_mask = 0;
    std::string display;
    std::string key;
    std::vector<std::int8_t> relation; // relation[i*length+j] in {-1,0,+1}
};

enum class StatisticKind {
    Ascents,
    Descents,
    WeakAscents,
    WeakDescents,
    EqualAdjacencies,
    MajorIndex,
    WeakMajorIndex,
    Inversions,
    Coinversions,
    Peaks,
    Valleys,
    LeftPeaks,
    FixedPoints,
    LetterSum,
    Maximum,
    StrictIncreasingRuns,
    StrictDecreasingRuns,
    WeakIncreasingRuns,
    WeakDecreasingRuns,
    SingletonLetters,
    RepeatedLetters,
    AscentSet,
    DescentSet,
    WeakAscentSet,
    WeakDescentSet,
    PeakSet,
    ValleySet,
    FixedPointSet,
    Evaluation
};

struct StatisticSpec {
    StatisticKind kind = StatisticKind::Descents;
    std::string id;
    std::string label;
};

struct StatisticValue {
    std::string order;
    std::string display;
};

using Distribution = std::unordered_map<std::string, Count>;

struct AvoidanceClass {
    std::string name;
    std::string column_name;
    std::vector<int> pattern_ids;
    std::string basis_display;
};

struct ActivePattern {
    const Pattern* pattern = nullptr;
    ClassMask class_mask = 0;
};

struct SearchContext {
    int n = 0;
    int k = 0;
    std::vector<ActivePattern> patterns;
    const std::vector<StatisticSpec>* statistics = nullptr;
};

struct ThreadAccumulator {
    std::vector<Count> avoiders;
    std::vector<std::string> catalog_buffers;
    std::vector<Distribution> statistic_counts; // class-major, then statistic
    Count search_nodes = 0;
    Count surviving_leaves = 0;

    explicit ThreadAccumulator(std::size_t class_count = 0,
                               bool catalog = false,
                               std::size_t statistic_count = 0)
        : avoiders(class_count, 0),
          catalog_buffers(catalog ? class_count : 0),
          statistic_counts(class_count * statistic_count) {}
};

struct FixedResult {
    int n = 0;
    int k = 0;
    Count cayley_words = 0;
    std::vector<Count> avoiders;
    std::vector<Distribution> statistic_counts; // class-major, then statistic
    Count search_nodes = 0;
    Count surviving_leaves = 0;
    std::uint64_t prefix_tasks = 0;
    int split_depth = 0;
    std::string engine = "analytic";
    double seconds = 0.0;
};

[[noreturn]] void fail(const std::string& message);

constexpr std::size_t CATALOG_FLUSH_BYTES = 1U << 20;

std::string catalog_filename(std::size_t class_index, int n, int k) {
    std::ostringstream name;
    name << "class_" << std::setw(3) << std::setfill('0') << (class_index + 1)
         << "_n_" << std::setw(3) << std::setfill('0') << n
         << "_k_" << std::setw(3) << std::setfill('0') << k << ".txt";
    return name.str();
}

class CatalogWriter {
public:
    CatalogWriter(const std::string& directory, int n, int k, std::size_t class_count)
        : enabled_(!directory.empty()), streams_(class_count), locks_(class_count) {
        if (!enabled_) return;
        std::filesystem::create_directories(native_path(directory));
        for (std::size_t c = 0; c < class_count; ++c) {
            const std::filesystem::path path =
                native_path(directory) / native_path(catalog_filename(c, n, k));
            streams_[c].open(path, std::ios::binary | std::ios::trunc);
            if (!streams_[c]) fail("cannot open catalogue output: " + path.string());
            locks_[c] = std::make_unique<std::mutex>();
        }
    }

    bool enabled() const noexcept { return enabled_; }

    void flush(std::size_t class_index, std::string& buffer) {
        if (!enabled_ || buffer.empty()) return;
        std::lock_guard<std::mutex> guard(*locks_[class_index]);
        streams_[class_index].write(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        if (!streams_[class_index]) fail("failed while writing an avoider catalogue");
        buffer.clear();
    }

    void finish() {
        if (!enabled_) return;
        for (auto& stream : streams_) stream.flush();
    }

private:
    bool enabled_ = false;
    std::vector<std::ofstream> streams_;
    std::vector<std::unique_ptr<std::mutex>> locks_;
};

[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error(message);
}

std::string trim(std::string text) {
    auto not_space = [](unsigned char c) { return !std::isspace(c); };
    text.erase(text.begin(), std::find_if(text.begin(), text.end(), not_space));
    text.erase(std::find_if(text.rbegin(), text.rend(), not_space).base(), text.end());
    return text;
}

std::vector<std::string> split(const std::string& text, char separator) {
    std::vector<std::string> pieces;
    std::string current;
    for (char c : text) {
        if (c == separator) {
            pieces.push_back(trim(current));
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    pieces.push_back(trim(current));
    return pieces;
}

std::string lower_ascii(std::string text);

int parse_int(const char* text, std::string_view option) {
    try {
        std::size_t used = 0;
        const std::string s(text);
        const int value = std::stoi(s, &used);
        if (used != s.size()) throw std::invalid_argument("trailing characters");
        return value;
    } catch (const std::exception&) {
        fail("invalid integer for " + std::string(option) + ": " + text);
    }
}

std::uint64_t parse_uint64(const char* text, std::string_view option) {
    try {
        std::size_t used = 0;
        const std::string s(text);
        if (!s.empty() && s.front() == '-') throw std::invalid_argument("negative");
        const auto value = std::stoull(s, &used);
        if (used != s.size()) throw std::invalid_argument("trailing characters");
        return static_cast<std::uint64_t>(value);
    } catch (const std::exception&) {
        fail("invalid nonnegative integer for " + std::string(option) + ": " + text);
    }
}

[[noreturn]] void print_usage(const std::string& error = {}) {
    if (!error.empty()) std::cerr << "error: " << error << "\n\n";
    std::cerr
        << "Pattern Engine 8 (native portable build)\n"
        << "Cayley permutations and restricted growth functions (RGFs)\n\n"
        << "Enumeration usage:\n"
        << "  PatternEngine --family cayley|rgf --max-n N --classes FILE [options]\n"
        << "  PatternEngine --family cayley|rgf --max-n N --class SPEC [--class SPEC ...] [options]\n\n"
        << "Other modes:\n"
        << "  PatternEngine --list-class C --list-n N --classes FILE --list-output FILE\n"
        << "  PatternEngine --inspect-word WORD --inspect-pattern PATTERN --inspect-output PREFIX\n"
        << "  PatternEngine --query-class C --query-n N --query-pattern PATTERN\n"
        << "                    --classes FILE --query-output FILE [options]\n"
        << "  PatternEngine --self-test\n\n"
        << "Pattern syntax:\n"
        << "  13442                         classical (bare patterns remain classical)\n"
        << "  classical:13442               explicit classical pattern\n"
        << "  consecutive:121               all selected positions must be adjacent\n"
        << "  vincular:1232|2               positions 2 and 3 in the occurrence are adjacent\n"
        << "  vincular:12321|1,3            bonds after pattern positions 1 and 3\n"
        << "  vincular:1,3,10,4|1,3         comma/space-separated ranks allow values >= 10\n"
        << "Aliases c:, con:, and v: are also accepted. Bond positions lie in 1,...,m-1.\n\n"
        << "Class syntax:\n"
        << "  name = pattern\n"
        << "  name = pattern + pattern + ...\n"
        << "Examples:\n"
        << "  avoid_13442 = 13442\n"
        << "  consecutive_example = consecutive:121\n"
        << "  mixed_basis = 13442 + vincular:1232|2 + consecutive:11\n\n"
        << "Enumeration options:\n"
        << "  --family F          cayley (default) or rgf\n"
        << "  --max-n N           compute every length n from --min-n through N\n"
        << "  --min-n N           first length to compute (default 0)\n"
        << "  --n N               alias for --max-n N\n"
        << "  --k K               only compute maximum K; for RGFs this is the number of blocks\n"
        << "  --threads T         worker threads; 0 uses all available hardware threads\n"
        << "  --split-depth D     prefix depth for parallel tasks; default automatic\n"
        << "  --engine MODE       auto, prefix, or leaf (default auto)\n"
        << "  --classes FILE      read one avoidance class per line\n"
        << "  --class SPEC        add a class directly; may be repeated\n"
        << "  --statistics FILE   collect distributions for statistic IDs in FILE\n"
        << "  --stat ID           collect one statistic; may be repeated\n"
        << "  --output PREFIX     write counts, metadata, and statistics when selected\n"
        << "  --catalog-dir DIR   additionally store every avoider in temporary catalogues\n"
        << "  --quiet             suppress per-(n,k) progress rows\n\n"
        << "Statistic IDs:\n"
        << "  ascents, descents, weak_ascents, weak_descents, equal_adjacencies,\n"
        << "  major_index, weak_major_index, inversions, coinversions, peaks, valleys,\n"
        << "  left_peaks, fixed_points, letter_sum, maximum, strict_increasing_runs,\n"
        << "  strict_decreasing_runs, weak_increasing_runs, weak_decreasing_runs,\n"
        << "  singleton_letters, repeated_letters, ascent_set, descent_set,\n"
        << "  weak_ascent_set, weak_descent_set, peak_set, valley_set, fixed_point_set,\n"
        << "  evaluation\n\n"
        << "Paged avoider listing mode:\n"
        << "  --list-class C      one-based class index\n"
        << "  --list-n N          length to list\n"
        << "  --k K               optionally require maximum K (number of blocks for RGFs)\n"
        << "  --offset O          skip the first O avoiders (default 0)\n"
        << "  --limit L           write at most L avoiders; 0 means all (default 100)\n"
        << "  --list-output FILE  one avoider per line in FILE\n\n"
        << "Single-word inspection mode:\n"
        << "  --inspect-word WORD       compact digits, or space/comma-separated entries\n"
        << "  --inspect-pattern PATTERN generalized pattern specification\n"
        << "  --inspect-output PREFIX   write PREFIX_summary.csv and PREFIX_occurrences.csv\n"
        << "  --inspect-limit L         list at most L occurrences (default 1000; 0 all)\n\n"
        << "Class-wide pattern-query mode:\n"
        << "  --query-class C      one-based avoidance-class index\n"
        << "  --query-n N          length to analyse\n"
        << "  --query-pattern P    pattern whose occurrence distribution is required\n"
        << "  --query-output FILE  output CSV file\n"
        << "  --k K                optionally restrict maximum/number of blocks\n\n"
        << "  --self-test         run detector, statistic, and enumerator validation tests\n"
        << "  --help, -h          show this message\n";
    std::exit(error.empty() ? 0 : 2);
}

Options parse_options(int argc, char** argv) {
    Options opt;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value_after = [&](std::string_view name) -> const char* {
            if (++i >= argc) print_usage("missing value after " + std::string(name));
            return argv[i];
        };

        if (arg == "--family" || arg == "--objects" || arg == "--object-family") {
            const std::string family = lower_ascii(value_after(arg));
            if (family == "cayley" || family == "cayley_permutations" || family == "cayley-permutations")
                opt.family = ObjectFamily::Cayley;
            else if (family == "rgf" || family == "rgfs" || family == "restricted_growth_functions" || family == "restricted-growth-functions")
                opt.family = ObjectFamily::RGF;
            else print_usage("--family must be cayley or rgf");
        }
        else if (arg == "--max-n" || arg == "--n") opt.max_n = parse_int(value_after(arg), arg);
        else if (arg == "--min-n") opt.min_n = parse_int(value_after(arg), arg);
        else if (arg == "--k") opt.only_k = parse_int(value_after(arg), arg);
        else if (arg == "--threads") opt.threads = parse_int(value_after(arg), arg);
        else if (arg == "--split-depth") opt.split_depth = parse_int(value_after(arg), arg);
        else if (arg == "--engine") {
            const std::string mode = value_after(arg);
            if (mode == "auto") opt.engine = EngineChoice::Auto;
            else if (mode == "prefix") opt.engine = EngineChoice::Prefix;
            else if (mode == "leaf") opt.engine = EngineChoice::Leaf;
            else print_usage("--engine must be auto, prefix, or leaf");
        }
        else if (arg == "--classes") opt.classes_file = value_after(arg);
        else if (arg == "--class") opt.class_specs.emplace_back(value_after(arg));
        else if (arg == "--statistics") opt.statistics_file = value_after(arg);
        else if (arg == "--stat") opt.statistic_specs.emplace_back(value_after(arg));
        else if (arg == "--output") opt.output_prefix = value_after(arg);
        else if (arg == "--catalog-dir") opt.catalog_dir = value_after(arg);
        else if (arg == "--list-class") { opt.list_mode = true; opt.list_class = parse_int(value_after(arg), arg); }
        else if (arg == "--list-n") opt.list_n = parse_int(value_after(arg), arg);
        else if (arg == "--offset") opt.list_offset = parse_uint64(value_after(arg), arg);
        else if (arg == "--limit") opt.list_limit = parse_uint64(value_after(arg), arg);
        else if (arg == "--list-output") opt.list_output = value_after(arg);
        else if (arg == "--inspect-word") { opt.inspect_mode = true; opt.inspect_word = value_after(arg); }
        else if (arg == "--inspect-pattern") opt.inspect_pattern = value_after(arg);
        else if (arg == "--inspect-output") opt.inspect_output_prefix = value_after(arg);
        else if (arg == "--inspect-limit") opt.inspect_limit = parse_uint64(value_after(arg), arg);
        else if (arg == "--query-class") { opt.query_mode = true; opt.query_class = parse_int(value_after(arg), arg); }
        else if (arg == "--query-n") opt.query_n = parse_int(value_after(arg), arg);
        else if (arg == "--query-pattern") opt.query_pattern = value_after(arg);
        else if (arg == "--query-output") opt.query_output = value_after(arg);
        else if (arg == "--quiet") opt.quiet = true;
        else if (arg == "--self-test") opt.self_test = true;
        else if (arg == "--help" || arg == "-h") print_usage();
        else print_usage("unknown option: " + arg);
    }

    if (opt.only_k < 0 || opt.only_k > MAX_N) print_usage("--k must lie between 0 and " + std::to_string(MAX_N));
    if (opt.threads < 0) print_usage("--threads must be nonnegative");
    if (opt.split_depth < -1 || opt.split_depth > MAX_N)
        print_usage("--split-depth must be -1 (automatic) or lie between 0 and " + std::to_string(MAX_N));

    const int active_modes = static_cast<int>(opt.list_mode) + static_cast<int>(opt.inspect_mode) + static_cast<int>(opt.query_mode);
    if (active_modes > 1) print_usage("listing, inspection, and class-wide query modes are mutually exclusive");
    const bool needs_classes = !opt.self_test && !opt.inspect_mode;
    if (needs_classes && opt.classes_file.empty() && opt.class_specs.empty())
        print_usage("supply --classes FILE or at least one --class SPEC");

    if (opt.inspect_mode) {
        if (opt.inspect_word.empty()) print_usage("--inspect-word may not be empty");
        if (opt.inspect_pattern.empty()) print_usage("--inspect-pattern is required");
        if (opt.inspect_output_prefix.empty()) print_usage("--inspect-output is required");
    } else if (opt.query_mode) {
        if (opt.query_class <= 0) print_usage("--query-class must be positive");
        if (opt.query_n < 0 || opt.query_n > MAX_N) print_usage("--query-n must lie between 0 and " + std::to_string(MAX_N));
        if (opt.query_pattern.empty()) print_usage("--query-pattern is required");
        if (opt.query_output.empty()) print_usage("--query-output is required");
    } else if (opt.list_mode) {
        if (opt.list_class <= 0) print_usage("--list-class must be positive");
        if (opt.list_n < 0 || opt.list_n > MAX_N) print_usage("--list-n must lie between 0 and " + std::to_string(MAX_N));
        if (opt.list_output.empty()) print_usage("--list-output is required in listing mode");
    } else if (!opt.self_test) {
        if (opt.min_n < 0 || opt.max_n < 0 || opt.min_n > opt.max_n) print_usage("require 0 <= --min-n <= --max-n");
        if (opt.max_n > MAX_N) print_usage("--max-n may not exceed " + std::to_string(MAX_N));
        if (opt.output_prefix.empty()) print_usage("--output may not be empty");
    }
    return opt;
}

std::string family_name(ObjectFamily family) {
    return family == ObjectFamily::RGF ? "rgf" : "cayley";
}

std::string family_label(ObjectFamily family) {
    return family == ObjectFamily::RGF ? "restricted growth functions" : "Cayley permutations";
}

std::string family_short_label(ObjectFamily family) {
    return family == ObjectFamily::RGF ? "RGF" : "Cayley";
}

std::string family_total_column(ObjectFamily family) {
    return family == ObjectFamily::RGF ? "rgf_words" : "cayley_words";
}

std::string engine_name(EngineChoice engine) {
    switch (engine) {
        case EngineChoice::Auto: return "auto";
        case EngineChoice::Prefix: return "prefix";
        case EngineChoice::Leaf: return "leaf";
    }
    return "unknown";
}

std::string count_to_string(Count value) {
    if (value == 0) return "0";
    std::string digits;
    while (value > 0) {
        const unsigned digit = static_cast<unsigned>(value % 10);
        digits.push_back(static_cast<char>('0' + digit));
        value /= 10;
    }
    std::reverse(digits.begin(), digits.end());
    return digits;
}

std::string signed_difference(Count a, Count b) {
    if (a >= b) return count_to_string(a - b);
    return "-" + count_to_string(b - a);
}

std::string csv_cell(const std::string& text) {
    if (text.find_first_of(",\"\n\r") == std::string::npos) return text;
    std::string escaped = "\"";
    for (char c : text) {
        if (c == '"') escaped += "\"\"";
        else escaped.push_back(c);
    }
    escaped.push_back('"');
    return escaped;
}

std::string lower_ascii(std::string text) {
    for (char& c : text) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return text;
}

std::vector<int> parse_positive_sequence(std::string token,
                                         const std::string& what,
                                         bool compact_allowed = true) {
    token = trim(token);
    if (token.empty()) fail("empty " + what);
    if ((token.front() == '[' && token.back() == ']') ||
        (token.front() == '(' && token.back() == ')') ||
        (token.front() == '{' && token.back() == '}'))
        token = trim(token.substr(1, token.size() - 2));
    bool all_digits = !token.empty();
    for (unsigned char c : token) if (!std::isdigit(c)) { all_digits = false; break; }
    std::vector<int> values;
    if (all_digits && compact_allowed) {
        for (char c : token) {
            if (c == '0') fail("compact " + what + " '" + token + "' contains 0; use spaces or commas for multi-digit entries");
            values.push_back(c - '0');
        }
    } else {
        std::string number;
        auto finish_number = [&]() {
            if (number.empty()) return;
            const int value = std::stoi(number);
            if (value <= 0) fail(what + " entries must be positive");
            values.push_back(value);
            number.clear();
        };
        for (unsigned char c : token) {
            if (std::isdigit(c)) number.push_back(static_cast<char>(c));
            else finish_number();
        }
        finish_number();
    }
    if (values.empty()) fail("could not parse " + what + " '" + token + "'");
    if (values.size() > static_cast<std::size_t>(MAX_N)) fail(what + " length exceeds the package limit " + std::to_string(MAX_N));
    return values;
}

std::string value_sequence_display(const std::vector<int>& values) {
    const int largest = values.empty() ? 0 : *std::max_element(values.begin(), values.end());
    if (largest <= 9) {
        std::string compact;
        for (int value : values) compact.push_back(static_cast<char>('0' + value));
        return compact;
    }
    std::ostringstream out;
    for (std::size_t i = 0; i < values.size(); ++i) { if (i) out << ' '; out << values[i]; }
    return out.str();
}

PatternType type_from_bonds(const std::vector<bool>& bonds) {
    if (bonds.empty() || std::none_of(bonds.begin(), bonds.end(), [](bool b){return b;})) return PatternType::Classical;
    if (std::all_of(bonds.begin(), bonds.end(), [](bool b){return b;})) return PatternType::Consecutive;
    return PatternType::Vincular;
}

std::string pattern_type_name(PatternType type) {
    switch (type) {
        case PatternType::Classical: return "classical";
        case PatternType::Consecutive: return "consecutive";
        case PatternType::Vincular: return "vincular";
    }
    return "unknown";
}

std::string pattern_key(const std::vector<int>& values, const std::vector<bool>& bonds) {
    std::ostringstream out;
    for (std::size_t i=0;i<values.size();++i) { if(i) out<<','; out<<values[i]; }
    out << '|'; for(bool bond:bonds) out<<(bond?'1':'0');
    return out.str();
}

std::string pattern_display(const std::vector<int>& values, const std::vector<bool>& bonds) {
    const std::string base=value_sequence_display(values);
    const PatternType type=type_from_bonds(bonds);
    if(type==PatternType::Classical) return base;
    if(type==PatternType::Consecutive) return "consecutive:"+base;
    std::ostringstream out; out<<"vincular:"<<base<<'|'; bool first=true;
    for(std::size_t i=0;i<bonds.size();++i) if(bonds[i]) { if(!first) out<<','; out<<(i+1); first=false; }
    return out.str();
}

struct ParsedPatternToken { std::vector<int> values; std::vector<bool> bonds; };

ParsedPatternToken parse_pattern_token(std::string token) {
    token=trim(token); if(token.empty()) fail("empty pattern in class specification");
    PatternType requested=PatternType::Classical;
    std::string lower=lower_ascii(token);
    auto remove_prefix=[&](const std::string& prefix, PatternType type)->bool {
        if(lower.rfind(prefix,0)!=0) return false;
        token=trim(token.substr(prefix.size())); lower=lower_ascii(token); requested=type; return true;
    };
    if(!(remove_prefix("classical:",PatternType::Classical)||remove_prefix("c:",PatternType::Classical)||
         remove_prefix("consecutive:",PatternType::Consecutive)||remove_prefix("con:",PatternType::Consecutive)||
         remove_prefix("vincular:",PatternType::Vincular)||remove_prefix("v:",PatternType::Vincular))) requested=PatternType::Classical;
    std::string value_text=token,bond_text;
    const std::size_t bar=token.find('|');
    if(bar!=std::string::npos) {
        value_text=trim(token.substr(0,bar)); bond_text=trim(token.substr(bar+1));
        if(token.find('|',bar+1)!=std::string::npos) fail("pattern contains more than one '|' separator: "+token);
    }
    ParsedPatternToken parsed;
    parsed.values=parse_positive_sequence(value_text,"pattern",true);
    const int m=static_cast<int>(parsed.values.size()); parsed.bonds.assign(m>0?static_cast<std::size_t>(m-1):0,false);
    if(requested==PatternType::Consecutive) {
        if(bar!=std::string::npos && !bond_text.empty()) fail("consecutive patterns do not need an explicit bond list: "+token);
        std::fill(parsed.bonds.begin(),parsed.bonds.end(),true);
    } else if(requested==PatternType::Vincular) {
        if(bar==std::string::npos) fail("vincular pattern requires '|bond positions', for example vincular:1232|2");
        if(!bond_text.empty()) {
            const auto positions=parse_positive_sequence(bond_text,"vincular bond list",false);
            for(int position:positions) {
                if(position<1||position>=m) fail("vincular bond position "+std::to_string(position)+" is outside 1,...,"+std::to_string(std::max(0,m-1)));
                parsed.bonds[static_cast<std::size_t>(position-1)]=true;
            }
        }
    } else if(bar!=std::string::npos) fail("an explicit bond list requires the vincular: prefix");
    const int largest=*std::max_element(parsed.values.begin(),parsed.values.end());
    std::vector<bool> seen(static_cast<std::size_t>(largest+1),false);
    for(int value:parsed.values) seen[static_cast<std::size_t>(value)]=true;
    for(int value=1;value<=largest;++value) if(!seen[static_cast<std::size_t>(value)])
        fail("pattern "+pattern_display(parsed.values,parsed.bonds)+" is not a Cayley pattern: its distinct ranks must be exactly 1,...,"+std::to_string(largest));
    return parsed;
}

DetectorKind detector_kind(const std::vector<int>& p,const std::vector<bool>& bonds) {
    if(std::any_of(bonds.begin(),bonds.end(),[](bool b){return b;})) return DetectorKind::Generic;
    if(p==std::vector<int>{1,1}) return DetectorKind::Pattern11;
    if(p==std::vector<int>{1,2}) return DetectorKind::Pattern12;
    if(p==std::vector<int>{2,1}) return DetectorKind::Pattern21;
    if(p==std::vector<int>{1,3,4,4,2}) return DetectorKind::Pattern13442;
    if(p==std::vector<int>{1,4,2,3,3}) return DetectorKind::Pattern14233;
    return DetectorKind::Generic;
}

Pattern make_pattern(const ParsedPatternToken& parsed) {
    Pattern p; p.values=parsed.values; p.bonds=parsed.bonds; p.type=type_from_bonds(p.bonds);
    p.length=static_cast<int>(p.values.size()); p.rank=*std::max_element(p.values.begin(),p.values.end()); p.defect=p.length-p.rank;
    p.detector=detector_kind(p.values,p.bonds); p.display=pattern_display(p.values,p.bonds); p.key=pattern_key(p.values,p.bonds);
    p.relation.resize(static_cast<std::size_t>(p.length*p.length),0);
    for(int i=0;i<p.length;++i) for(int j=0;j<p.length;++j) {
        const int relation=(p.values[i]<p.values[j])?-1:(p.values[i]>p.values[j])?1:0;
        p.relation[static_cast<std::size_t>(i*p.length+j)]=static_cast<std::int8_t>(relation);
    }
    return p;
}
Pattern parse_single_pattern(const std::string& text) { return make_pattern(parse_pattern_token(text)); }

std::string normalize_statistic_id(std::string text) {
    text=lower_ascii(trim(text));
    for(char& c:text) if(c==' '||c=='-'||c=='.') c='_';
    while(text.find("__")!=std::string::npos) text.replace(text.find("__"),2,"_");
    return text;
}

StatisticSpec parse_statistic_spec(const std::string& raw) {
    const std::string id=normalize_statistic_id(raw);
    const std::unordered_map<std::string,StatisticSpec> table={
        {"ascents",{StatisticKind::Ascents,"ascents","Number of ascents"}},{"asc",{StatisticKind::Ascents,"ascents","Number of ascents"}},
        {"descents",{StatisticKind::Descents,"descents","Number of descents"}},{"des",{StatisticKind::Descents,"descents","Number of descents"}},
        {"weak_ascents",{StatisticKind::WeakAscents,"weak_ascents","Number of weak ascents"}},{"wasc",{StatisticKind::WeakAscents,"weak_ascents","Number of weak ascents"}},
        {"weak_descents",{StatisticKind::WeakDescents,"weak_descents","Number of weak descents"}},{"wdes",{StatisticKind::WeakDescents,"weak_descents","Number of weak descents"}},
        {"equal_adjacencies",{StatisticKind::EqualAdjacencies,"equal_adjacencies","Number of equal adjacencies"}},{"levels",{StatisticKind::EqualAdjacencies,"equal_adjacencies","Number of equal adjacencies"}},
        {"major_index",{StatisticKind::MajorIndex,"major_index","Major index"}},{"maj",{StatisticKind::MajorIndex,"major_index","Major index"}},
        {"weak_major_index",{StatisticKind::WeakMajorIndex,"weak_major_index","Weak major index"}},{"wmaj",{StatisticKind::WeakMajorIndex,"weak_major_index","Weak major index"}},
        {"inversions",{StatisticKind::Inversions,"inversions","Number of inversions"}},{"inv",{StatisticKind::Inversions,"inversions","Number of inversions"}},
        {"coinversions",{StatisticKind::Coinversions,"coinversions","Number of coinversions"}},{"coinv",{StatisticKind::Coinversions,"coinversions","Number of coinversions"}},
        {"peaks",{StatisticKind::Peaks,"peaks","Number of peaks"}},{"valleys",{StatisticKind::Valleys,"valleys","Number of valleys"}},
        {"left_peaks",{StatisticKind::LeftPeaks,"left_peaks","Number of left peaks"}},
        {"fixed_points",{StatisticKind::FixedPoints,"fixed_points","Number of fixed points"}},{"fp",{StatisticKind::FixedPoints,"fixed_points","Number of fixed points"}},
        {"letter_sum",{StatisticKind::LetterSum,"letter_sum","Sum of letters"}},{"sum",{StatisticKind::LetterSum,"letter_sum","Sum of letters"}},
        {"maximum",{StatisticKind::Maximum,"maximum","Maximum letter"}},{"max",{StatisticKind::Maximum,"maximum","Maximum letter"}},
        {"strict_increasing_runs",{StatisticKind::StrictIncreasingRuns,"strict_increasing_runs","Number of strictly increasing runs"}},
        {"strict_decreasing_runs",{StatisticKind::StrictDecreasingRuns,"strict_decreasing_runs","Number of strictly decreasing runs"}},
        {"weak_increasing_runs",{StatisticKind::WeakIncreasingRuns,"weak_increasing_runs","Number of weakly increasing runs"}},
        {"weak_decreasing_runs",{StatisticKind::WeakDecreasingRuns,"weak_decreasing_runs","Number of weakly decreasing runs"}},
        {"singleton_letters",{StatisticKind::SingletonLetters,"singleton_letters","Number of singleton letters"}},{"singletons",{StatisticKind::SingletonLetters,"singleton_letters","Number of singleton letters"}},
        {"repeated_letters",{StatisticKind::RepeatedLetters,"repeated_letters","Number of repeated letters"}},
        {"ascent_set",{StatisticKind::AscentSet,"ascent_set","Ascent set"}},{"asc_set",{StatisticKind::AscentSet,"ascent_set","Ascent set"}},
        {"descent_set",{StatisticKind::DescentSet,"descent_set","Descent set"}},{"des_set",{StatisticKind::DescentSet,"descent_set","Descent set"}},
        {"weak_ascent_set",{StatisticKind::WeakAscentSet,"weak_ascent_set","Weak ascent set"}},
        {"weak_descent_set",{StatisticKind::WeakDescentSet,"weak_descent_set","Weak descent set"}},
        {"peak_set",{StatisticKind::PeakSet,"peak_set","Peak set"}},{"valley_set",{StatisticKind::ValleySet,"valley_set","Valley set"}},
        {"fixed_point_set",{StatisticKind::FixedPointSet,"fixed_point_set","Fixed-point set"}},
        {"evaluation",{StatisticKind::Evaluation,"evaluation","Evaluation"}},{"content",{StatisticKind::Evaluation,"evaluation","Evaluation"}}
    };
    const auto found=table.find(id); if(found==table.end()) fail("unknown statistic '"+raw+"'; run --help for the supported IDs");
    return found->second;
}

std::vector<StatisticSpec> parse_statistics(const Options& opt) {
    std::vector<std::string> raw=opt.statistic_specs;
    if(!opt.statistics_file.empty()) {
        std::ifstream input(native_path(opt.statistics_file)); if(!input) fail("cannot open statistics file: "+opt.statistics_file);
        std::string line; while(std::getline(input,line)) { const auto hash=line.find('#'); if(hash!=std::string::npos) line.erase(hash); line=trim(line); if(!line.empty()) raw.push_back(line); }
    }
    std::vector<StatisticSpec> result; std::unordered_set<std::string> used;
    for(const auto& text:raw) { auto spec=parse_statistic_spec(text); if(used.insert(spec.id).second) result.push_back(std::move(spec)); }
    return result;
}

std::string make_column_name(std::string name, std::size_t index,
                             std::unordered_set<std::string>& used) {
    std::string result;
    for (unsigned char c : name) {
        if (std::isalnum(c)) result.push_back(static_cast<char>(c));
        else result.push_back('_');
    }
    while (!result.empty() && result.front() == '_') result.erase(result.begin());
    while (!result.empty() && result.back() == '_') result.pop_back();
    if (result.empty()) result = "class_" + std::to_string(index + 1);
    std::string unique = result;
    int suffix = 2;
    while (used.contains(unique)) unique = result + "_" + std::to_string(suffix++);
    used.insert(unique);
    return unique;
}

struct ParsedInput {
    std::vector<AvoidanceClass> classes;
    std::vector<Pattern> patterns;
};

ParsedInput parse_classes(const Options& opt) {
    std::vector<std::string> specifications = opt.class_specs;
    if (!opt.classes_file.empty()) {
        std::ifstream input(native_path(opt.classes_file));
        if (!input) fail("cannot open classes file: " + opt.classes_file);
        std::string line;
        int line_number = 0;
        while (std::getline(input, line)) {
            ++line_number;
            const std::size_t hash = line.find('#');
            if (hash != std::string::npos) line.erase(hash);
            line = trim(line);
            if (line.empty()) continue;
            specifications.push_back(line);
        }
    }

    if (specifications.empty()) fail("no avoidance classes were supplied");
    if (specifications.size() > MAX_CLASSES)
        fail("at most " + std::to_string(MAX_CLASSES) + " classes may be compared in one run");

    ParsedInput parsed;
    std::unordered_map<std::string, int> pattern_id;
    std::unordered_set<std::string> used_columns = {
        "n", "k", "cayley_words", "difference_1_minus_2", "seconds",
        "engine", "search_nodes", "surviving_leaves", "prefix_tasks", "split_depth"
    };

    for (std::size_t class_index = 0; class_index < specifications.size(); ++class_index) {
        std::string spec = trim(specifications[class_index]);
        const std::size_t equals = spec.find('=');
        std::string name;
        std::string basis_text;
        if (equals == std::string::npos) {
            basis_text = spec;
        } else {
            name = trim(spec.substr(0, equals));
            basis_text = trim(spec.substr(equals + 1));
            if (name.empty()) fail("empty class name in specification: " + spec);
        }
        if (basis_text.empty()) fail("empty basis in class specification: " + spec);

        std::vector<std::string> tokens = split(basis_text, '+');
        std::vector<int> ids;
        std::unordered_set<int> already_in_class;
        std::vector<std::string> displays;
        for (const std::string& token : tokens) {
            const ParsedPatternToken parsed_token = parse_pattern_token(token);
            const std::string key = pattern_key(parsed_token.values, parsed_token.bonds);
            int id = 0;
            auto found = pattern_id.find(key);
            if (found == pattern_id.end()) {
                id = static_cast<int>(parsed.patterns.size());
                pattern_id.emplace(key, id);
                parsed.patterns.push_back(make_pattern(parsed_token));
            } else {
                id = found->second;
            }
            if (already_in_class.insert(id).second) {
                ids.push_back(id);
                displays.push_back(parsed.patterns[static_cast<std::size_t>(id)].display);
            }
        }
        if (ids.empty()) fail("empty basis in class specification: " + spec);

        if (name.empty()) {
            std::ostringstream automatic;
            automatic << "Av(";
            for (std::size_t i = 0; i < displays.size(); ++i) {
                if (i) automatic << ',';
                automatic << displays[i];
            }
            automatic << ')';
            name = automatic.str();
        }

        std::ostringstream basis_display;
        for (std::size_t i = 0; i < displays.size(); ++i) {
            if (i) basis_display << " + ";
            basis_display << displays[i];
        }

        AvoidanceClass cls;
        cls.name = name;
        cls.column_name = make_column_name(name, class_index, used_columns);
        cls.pattern_ids = std::move(ids);
        cls.basis_display = basis_display.str();
        parsed.classes.push_back(std::move(cls));
    }

    for (std::size_t class_index = 0; class_index < parsed.classes.size(); ++class_index) {
        const ClassMask bit = ClassMask{1} << class_index;
        for (int id : parsed.classes[class_index].pattern_ids)
            parsed.patterns[static_cast<std::size_t>(id)].class_mask |= bit;
    }
    return parsed;
}

Count factorial(int n) {
    Count answer = 1;
    for (int i = 2; i <= n; ++i) answer *= static_cast<unsigned>(i);
    return answer;
}

Count stirling_second(int n, int k) {
    static std::array<std::array<Count, MAX_N + 1>, MAX_N + 1> table{};
    static bool initialized = false;
    if (!initialized) {
        table[0][0] = 1;
        for (int i = 1; i <= MAX_N; ++i) {
            for (int j = 1; j <= i; ++j) {
                table[i][j] = table[i - 1][j - 1]
                            + static_cast<unsigned>(j) * table[i - 1][j];
            }
        }
        initialized = true;
    }
    return table[n][k];
}

Count cayley_words(int n, int k) {
    if (n == 0 && k == 0) return 1;
    if (n <= 0 || k <= 0 || k > n) return 0;
    return factorial(k) * stirling_second(n, k);
}

Count rgf_words(int n, int k) {
    if (n == 0 && k == 0) return 1;
    if (n <= 0 || k <= 0 || k > n) return 0;
    return stirling_second(n, k);
}

Count family_words(ObjectFamily family, int n, int k) {
    return family == ObjectFamily::RGF ? rgf_words(n, k) : cayley_words(n, k);
}

bool new_11(const std::array<std::uint8_t, MAX_N>& word, int length) {
    if (length < 2) return false;
    const std::uint8_t last = word[static_cast<std::size_t>(length - 1)];
    for (int i = 0; i < length - 1; ++i)
        if (word[static_cast<std::size_t>(i)] == last) return true;
    return false;
}

bool new_12(const std::array<std::uint8_t, MAX_N>& word, int length) {
    if (length < 2) return false;
    const std::uint8_t last = word[static_cast<std::size_t>(length - 1)];
    for (int i = 0; i < length - 1; ++i)
        if (word[static_cast<std::size_t>(i)] < last) return true;
    return false;
}

bool new_21(const std::array<std::uint8_t, MAX_N>& word, int length) {
    if (length < 2) return false;
    const std::uint8_t last = word[static_cast<std::size_t>(length - 1)];
    for (int i = 0; i < length - 1; ++i)
        if (word[static_cast<std::size_t>(i)] > last) return true;
    return false;
}

bool new_13442(const std::array<std::uint8_t, MAX_N>& word,
                 const std::array<std::uint8_t, MAX_N>& before,
                 int length) {
    if (length < 5) return false;
    const int last_index = length - 1;
    const int second = word[static_cast<std::size_t>(last_index)];
    for (int i3 = 2; i3 <= last_index - 2; ++i3) {
        const int high = word[static_cast<std::size_t>(i3)];
        if (high <= second) continue;
        for (int i4 = i3 + 1; i4 < last_index; ++i4) {
            if (word[static_cast<std::size_t>(i4)] != high) continue;
            for (int i2 = 1; i2 < i3; ++i2) {
                const int middle = word[static_cast<std::size_t>(i2)];
                if (second < middle && middle < high
                    && before[static_cast<std::size_t>(i2)] < second)
                    return true;
            }
        }
    }
    return false;
}

bool new_14233(const std::array<std::uint8_t, MAX_N>& word,
                 const std::array<std::uint8_t, MAX_N>& before,
                 int length) {
    if (length < 5) return false;
    const int last_index = length - 1;
    const int repeated = word[static_cast<std::size_t>(last_index)];
    for (int i4 = 3; i4 < last_index; ++i4) {
        if (word[static_cast<std::size_t>(i4)] != repeated) continue;
        for (int i2 = 1; i2 <= i4 - 2; ++i2) {
            const int high = word[static_cast<std::size_t>(i2)];
            const int low = before[static_cast<std::size_t>(i2)];
            if (high <= repeated) continue;
            for (int i3 = i2 + 1; i3 < i4; ++i3) {
                const int second = word[static_cast<std::size_t>(i3)];
                if (low < second && second < repeated) return true;
            }
        }
    }
    return false;
}

bool contains_11_full(const std::array<std::uint8_t, MAX_N>& word, int n) {
    for (int j = 1; j < n; ++j)
        for (int i = 0; i < j; ++i)
            if (word[static_cast<std::size_t>(i)] == word[static_cast<std::size_t>(j)])
                return true;
    return false;
}

bool contains_12_full(const std::array<std::uint8_t, MAX_N>& word, int n) {
    if (n < 2) return false;
    std::uint8_t minimum = word[0];
    for (int j = 1; j < n; ++j) {
        if (minimum < word[static_cast<std::size_t>(j)]) return true;
        minimum = std::min(minimum, word[static_cast<std::size_t>(j)]);
    }
    return false;
}

bool contains_21_full(const std::array<std::uint8_t, MAX_N>& word, int n) {
    if (n < 2) return false;
    std::uint8_t maximum = word[0];
    for (int j = 1; j < n; ++j) {
        if (maximum > word[static_cast<std::size_t>(j)]) return true;
        maximum = std::max(maximum, word[static_cast<std::size_t>(j)]);
    }
    return false;
}

bool contains_13442_full(const std::array<std::uint8_t, MAX_N>& word, int n) {
    if (n < 5) return false;
    std::array<std::uint8_t, MAX_N> before{};
    before[0] = std::numeric_limits<std::uint8_t>::max();
    for (int i = 1; i < n; ++i)
        before[static_cast<std::size_t>(i)] = std::min(
            before[static_cast<std::size_t>(i - 1)],
            word[static_cast<std::size_t>(i - 1)]);

    for (int i3 = 2; i3 <= n - 3; ++i3) {
        const int high = word[static_cast<std::size_t>(i3)];
        for (int i4 = i3 + 1; i4 <= n - 2; ++i4) {
            if (word[static_cast<std::size_t>(i4)] != high) continue;
            for (int i2 = 1; i2 < i3; ++i2) {
                const int middle = word[static_cast<std::size_t>(i2)];
                const int low = before[static_cast<std::size_t>(i2)];
                if (!(low < middle && middle < high)) continue;
                for (int i5 = i4 + 1; i5 < n; ++i5) {
                    const int second = word[static_cast<std::size_t>(i5)];
                    if (low < second && second < middle) return true;
                }
            }
        }
    }
    return false;
}

bool contains_14233_full(const std::array<std::uint8_t, MAX_N>& word, int n) {
    if (n < 5) return false;
    std::array<std::uint8_t, MAX_N> before{};
    before[0] = std::numeric_limits<std::uint8_t>::max();
    for (int i = 1; i < n; ++i)
        before[static_cast<std::size_t>(i)] = std::min(
            before[static_cast<std::size_t>(i - 1)],
            word[static_cast<std::size_t>(i - 1)]);

    for (int i4 = 3; i4 <= n - 2; ++i4) {
        const int repeated = word[static_cast<std::size_t>(i4)];
        bool later_copy = false;
        for (int i5 = i4 + 1; i5 < n; ++i5) {
            if (word[static_cast<std::size_t>(i5)] == repeated) {
                later_copy = true;
                break;
            }
        }
        if (!later_copy) continue;
        for (int i2 = 1; i2 <= i4 - 2; ++i2) {
            const int high = word[static_cast<std::size_t>(i2)];
            const int low = before[static_cast<std::size_t>(i2)];
            if (high <= repeated) continue;
            for (int i3 = i2 + 1; i3 < i4; ++i3) {
                const int second = word[static_cast<std::size_t>(i3)];
                if (low < second && second < repeated) return true;
            }
        }
    }
    return false;
}

bool compatible_with_later(const Pattern& pattern,int pattern_position,int candidate,const std::array<std::uint8_t,MAX_N>& chosen_values) {
    for(int later=pattern_position+1;later<pattern.length;++later) {
        const int relation=pattern.relation[static_cast<std::size_t>(pattern_position*pattern.length+later)];
        const int later_value=chosen_values[static_cast<std::size_t>(later)];
        if(relation<0&&!(candidate<later_value)) return false;
        if(relation>0&&!(candidate>later_value)) return false;
        if(relation==0&&candidate!=later_value) return false;
    }
    return true;
}

bool generic_choose_earlier(const Pattern& pattern,const std::array<std::uint8_t,MAX_N>& word,int pattern_position,int largest_word_index,
                            std::array<std::uint8_t,MAX_N>& chosen_values,std::array<int,MAX_N>& chosen_indices) {
    if(pattern_position<0) return true;
    int first_index=largest_word_index,last_index=pattern_position;
    if(pattern.bonds[static_cast<std::size_t>(pattern_position)]) {
        first_index=chosen_indices[static_cast<std::size_t>(pattern_position+1)]-1; last_index=first_index;
        if(first_index<pattern_position||first_index>largest_word_index) return false;
    }
    for(int word_index=first_index;word_index>=last_index;--word_index) {
        const int candidate=word[static_cast<std::size_t>(word_index)];
        if(!compatible_with_later(pattern,pattern_position,candidate,chosen_values)) continue;
        chosen_values[static_cast<std::size_t>(pattern_position)]=static_cast<std::uint8_t>(candidate);
        chosen_indices[static_cast<std::size_t>(pattern_position)]=word_index;
        if(generic_choose_earlier(pattern,word,pattern_position-1,word_index-1,chosen_values,chosen_indices)) return true;
        if(pattern.bonds[static_cast<std::size_t>(pattern_position)]) break;
    }
    return false;
}

bool new_generic_occurrence(const Pattern& pattern,const std::array<std::uint8_t,MAX_N>& word,int length) {
    if(length<pattern.length) return false;
    std::array<std::uint8_t,MAX_N> chosen_values{}; std::array<int,MAX_N> chosen_indices{};
    chosen_values[static_cast<std::size_t>(pattern.length-1)]=word[static_cast<std::size_t>(length-1)];
    chosen_indices[static_cast<std::size_t>(pattern.length-1)]=length-1;
    return generic_choose_earlier(pattern,word,pattern.length-2,length-2,chosen_values,chosen_indices);
}

bool new_occurrence(const Pattern& pattern,
                    const std::array<std::uint8_t, MAX_N>& word,
                    const std::array<std::uint8_t, MAX_N>& before,
                    int length) {
    switch (pattern.detector) {
        case DetectorKind::Pattern11: return new_11(word, length);
        case DetectorKind::Pattern12: return new_12(word, length);
        case DetectorKind::Pattern21: return new_21(word, length);
        case DetectorKind::Pattern13442: return new_13442(word, before, length);
        case DetectorKind::Pattern14233: return new_14233(word, before, length);
        case DetectorKind::Generic: return new_generic_occurrence(pattern, word, length);
    }
    return false;
}

bool contains_full(const Pattern& pattern,
                   const std::array<std::uint8_t, MAX_N>& word,
                   int n) {
    switch (pattern.detector) {
        case DetectorKind::Pattern11: return contains_11_full(word, n);
        case DetectorKind::Pattern12: return contains_12_full(word, n);
        case DetectorKind::Pattern21: return contains_21_full(word, n);
        case DetectorKind::Pattern13442: return contains_13442_full(word, n);
        case DetectorKind::Pattern14233: return contains_14233_full(word, n);
        case DetectorKind::Generic: {
            std::array<std::uint8_t, MAX_N> before{};
            for (int length = pattern.length; length <= n; ++length) {
                const int position = length - 1;
                before[static_cast<std::size_t>(position)] = position == 0
                    ? std::numeric_limits<std::uint8_t>::max()
                    : std::min(before[static_cast<std::size_t>(position - 1)],
                               word[static_cast<std::size_t>(position - 1)]);
                if (new_generic_occurrence(pattern, word, length)) return true;
            }
            return false;
        }
    }
    return false;
}

ClassMask update_alive(ClassMask alive,
                       const std::array<std::uint8_t, MAX_N>& word,
                       const std::array<std::uint8_t, MAX_N>& before,
                       int length,
                       const std::vector<ActivePattern>& patterns) {
    for (const ActivePattern& active : patterns) {
        const ClassMask affected = alive & active.class_mask;
        if (affected == 0) continue;
        if (length < active.pattern->length) continue;
        if (new_occurrence(*active.pattern, word, before, length)) {
            alive &= ~active.class_mask;
            if (alive == 0) break;
        }
    }
    return alive;
}

std::string format_word(const std::array<std::uint8_t, MAX_N>& word, int n, int k) {
    if (n == 0) return "epsilon";
    std::ostringstream out;
    const bool spaced = k >= 10;
    for (int i = 0; i < n; ++i) {
        if (spaced && i != 0) out << ' ';
        out << (static_cast<unsigned>(word[static_cast<std::size_t>(i)]) + 1U);
    }
    return out.str();
}

std::string padded_unsigned(std::uint64_t value,int width=20) { std::ostringstream out; out<<std::setw(width)<<std::setfill('0')<<value; return out.str(); }
std::string set_display(std::uint64_t mask,int maximum_position) { std::ostringstream out; out<<'{'; bool first=true; for(int position=1;position<=maximum_position;++position) if(mask&(std::uint64_t{1}<<(position-1))) { if(!first) out<<','; out<<position; first=false; } out<<'}'; return out.str(); }

struct WordStatisticCache {
 int ascents=0,descents=0,weak_ascents=0,weak_descents=0,equal_adjacencies=0,major_index=0,weak_major_index=0;
 int inversions=0,coinversions=0,peaks=0,valleys=0,left_peaks=0,fixed_points=0,letter_sum=0,maximum=0;
 int strict_increasing_runs=0,strict_decreasing_runs=0,weak_increasing_runs=0,weak_decreasing_runs=0,singleton_letters=0,repeated_letters=0;
 std::uint64_t ascent_set=0,descent_set=0,weak_ascent_set=0,weak_descent_set=0,peak_set=0,valley_set=0,fixed_point_set=0;
 std::vector<int> evaluation;
};

WordStatisticCache compute_word_statistics(const std::array<std::uint8_t,MAX_N>& word,int n,int k) {
 WordStatisticCache c; c.maximum=k; c.evaluation.assign(static_cast<std::size_t>(k),0);
 for(int i=0;i<n;++i) { const int value=static_cast<int>(word[static_cast<std::size_t>(i)])+1; c.letter_sum+=value; if(value>=1&&value<=k) ++c.evaluation[static_cast<std::size_t>(value-1)]; if(value==i+1){++c.fixed_points;c.fixed_point_set|=std::uint64_t{1}<<i;} }
 for(int i=0;i+1<n;++i) { const int left=word[static_cast<std::size_t>(i)],right=word[static_cast<std::size_t>(i+1)]; const auto bit=std::uint64_t{1}<<i;
   if(left<right){++c.ascents;c.ascent_set|=bit;} if(left>right){++c.descents;c.descent_set|=bit;c.major_index+=i+1;}
   if(left<=right){++c.weak_ascents;c.weak_ascent_set|=bit;} if(left>=right){++c.weak_descents;c.weak_descent_set|=bit;c.weak_major_index+=i+1;} if(left==right)++c.equal_adjacencies;
 }
 for(int i=0;i<n;++i) for(int j=i+1;j<n;++j) { const int a=word[static_cast<std::size_t>(i)],b=word[static_cast<std::size_t>(j)]; if(a>b)++c.inversions; else if(a<b)++c.coinversions; }
 for(int i=1;i+1<n;++i) { const int a=word[static_cast<std::size_t>(i-1)],b=word[static_cast<std::size_t>(i)],d=word[static_cast<std::size_t>(i+1)]; const auto bit=std::uint64_t{1}<<i; if(a<b&&b>d){++c.peaks;c.peak_set|=bit;} if(a>b&&b<d){++c.valleys;c.valley_set|=bit;} }
 if(n>=2&&word[0]>word[1])++c.left_peaks;
 c.left_peaks+=c.peaks;
 if(n>0){c.strict_increasing_runs=c.weak_descents+1;c.strict_decreasing_runs=c.weak_ascents+1;c.weak_increasing_runs=c.descents+1;c.weak_decreasing_runs=c.ascents+1;}
 for(int f:c.evaluation){if(f==1)++c.singleton_letters;else if(f>=2)++c.repeated_letters;} return c;
}
StatisticValue scalar_stat_value(std::uint64_t value){return {padded_unsigned(value),std::to_string(value)};}
StatisticValue set_stat_value(std::uint64_t mask,int maximum_position){return {padded_unsigned(mask),set_display(mask,maximum_position)};}
StatisticValue statistic_value(const StatisticSpec& spec,const WordStatisticCache& c,int n) {
 switch(spec.kind) {
 case StatisticKind::Ascents:return scalar_stat_value(c.ascents); case StatisticKind::Descents:return scalar_stat_value(c.descents); case StatisticKind::WeakAscents:return scalar_stat_value(c.weak_ascents); case StatisticKind::WeakDescents:return scalar_stat_value(c.weak_descents);
 case StatisticKind::EqualAdjacencies:return scalar_stat_value(c.equal_adjacencies); case StatisticKind::MajorIndex:return scalar_stat_value(c.major_index); case StatisticKind::WeakMajorIndex:return scalar_stat_value(c.weak_major_index); case StatisticKind::Inversions:return scalar_stat_value(c.inversions); case StatisticKind::Coinversions:return scalar_stat_value(c.coinversions);
 case StatisticKind::Peaks:return scalar_stat_value(c.peaks); case StatisticKind::Valleys:return scalar_stat_value(c.valleys); case StatisticKind::LeftPeaks:return scalar_stat_value(c.left_peaks); case StatisticKind::FixedPoints:return scalar_stat_value(c.fixed_points); case StatisticKind::LetterSum:return scalar_stat_value(c.letter_sum); case StatisticKind::Maximum:return scalar_stat_value(c.maximum);
 case StatisticKind::StrictIncreasingRuns:return scalar_stat_value(c.strict_increasing_runs); case StatisticKind::StrictDecreasingRuns:return scalar_stat_value(c.strict_decreasing_runs); case StatisticKind::WeakIncreasingRuns:return scalar_stat_value(c.weak_increasing_runs); case StatisticKind::WeakDecreasingRuns:return scalar_stat_value(c.weak_decreasing_runs); case StatisticKind::SingletonLetters:return scalar_stat_value(c.singleton_letters); case StatisticKind::RepeatedLetters:return scalar_stat_value(c.repeated_letters);
 case StatisticKind::AscentSet:return set_stat_value(c.ascent_set,std::max(0,n-1)); case StatisticKind::DescentSet:return set_stat_value(c.descent_set,std::max(0,n-1)); case StatisticKind::WeakAscentSet:return set_stat_value(c.weak_ascent_set,std::max(0,n-1)); case StatisticKind::WeakDescentSet:return set_stat_value(c.weak_descent_set,std::max(0,n-1)); case StatisticKind::PeakSet:return set_stat_value(c.peak_set,n); case StatisticKind::ValleySet:return set_stat_value(c.valley_set,n); case StatisticKind::FixedPointSet:return set_stat_value(c.fixed_point_set,n);
 case StatisticKind::Evaluation:{std::ostringstream display,order;display<<'(';for(std::size_t i=0;i<c.evaluation.size();++i){if(i)display<<',';display<<c.evaluation[i];order<<std::setw(3)<<std::setfill('0')<<c.evaluation[i];}display<<')';return {order.str(),display.str()};}
 }
 return {"",""};
}
std::string encode_statistic_value(const StatisticValue& value){return value.order+static_cast<char>(0x1f)+value.display;}
std::pair<std::string,std::string> decode_statistic_value(const std::string& key){const auto pos=key.find(static_cast<char>(0x1f));if(pos==std::string::npos)return{key,key};return{key.substr(0,pos),key.substr(pos+1)};}

void record_alive_leaf(ClassMask alive,const std::array<std::uint8_t,MAX_N>& word,const SearchContext& context,ThreadAccumulator& accumulator,CatalogWriter* catalog_writer) {
 std::string formatted; if(catalog_writer&&catalog_writer->enabled()) formatted=format_word(word,context.n,context.k)+'\n';
 std::vector<std::string> statistic_keys; const std::size_t statistic_count=context.statistics?context.statistics->size():0;
 if(statistic_count>0){const auto cache=compute_word_statistics(word,context.n,context.k);statistic_keys.reserve(statistic_count);for(const auto& spec:*context.statistics)statistic_keys.push_back(encode_statistic_value(statistic_value(spec,cache,context.n)));}
 while(alive!=0){const unsigned bit=std::countr_zero(alive);++accumulator.avoiders[bit];if(catalog_writer&&catalog_writer->enabled()){auto& buffer=accumulator.catalog_buffers[bit];buffer+=formatted;if(buffer.size()>=CATALOG_FLUSH_BYTES)catalog_writer->flush(bit,buffer);}for(std::size_t j=0;j<statistic_count;++j)++accumulator.statistic_counts[static_cast<std::size_t>(bit)*statistic_count+j][statistic_keys[j]];alive&=alive-1;}
}

void enumerate_suffix(int position,
                      LetterMask used,
                      ClassMask alive,
                      std::array<std::uint8_t, MAX_N>& word,
                      std::array<std::uint8_t, MAX_N>& before,
                      const SearchContext& context,
                      ThreadAccumulator& accumulator,
                      CatalogWriter* catalog_writer) {
    ++accumulator.search_nodes;
    const int remaining = context.n - position;
    const int missing = context.k - std::popcount(used);
    if (missing > remaining || alive == 0) return;

    if (position == context.n) {
        if (missing != 0) return;
        ++accumulator.surviving_leaves;
        record_alive_leaf(alive, word, context, accumulator, catalog_writer);
        return;
    }

    before[static_cast<std::size_t>(position)] = position == 0
        ? std::numeric_limits<std::uint8_t>::max()
        : std::min(before[static_cast<std::size_t>(position - 1)],
                   word[static_cast<std::size_t>(position - 1)]);
    for (int letter = 0; letter < context.k; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        const ClassMask next_alive = update_alive(
            alive, word, before, position + 1, context.patterns);
        enumerate_suffix(position + 1,
                         used | (LetterMask{1} << letter),
                         next_alive, word, before, context, accumulator, catalog_writer);
    }
}

void enumerate_suffix_leaf(int position,
                           LetterMask used,
                           ClassMask initial_alive,
                           std::array<std::uint8_t, MAX_N>& word,
                           const SearchContext& context,
                           ThreadAccumulator& accumulator,
                           CatalogWriter* catalog_writer) {
    ++accumulator.search_nodes;
    const int remaining = context.n - position;
    const int missing = context.k - std::popcount(used);
    if (missing > remaining) return;

    if (position == context.n) {
        if (missing != 0) return;
        ClassMask alive = initial_alive;
        for (const ActivePattern& active : context.patterns) {
            if ((alive & active.class_mask) == 0) continue;
            if (contains_full(*active.pattern, word, context.n)) {
                alive &= ~active.class_mask;
                if (alive == 0) break;
            }
        }
        if (alive != 0) {
            ++accumulator.surviving_leaves;
            record_alive_leaf(alive, word, context, accumulator, catalog_writer);
        }
        return;
    }

    for (int letter = 0; letter < context.k; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        enumerate_suffix_leaf(position + 1,
                              used | (LetterMask{1} << letter),
                              initial_alive, word, context, accumulator, catalog_writer);
    }
}

bool automatic_leaf_engine(const std::vector<ActivePattern>& patterns) {
    if (patterns.empty()) return false;
    for (const ActivePattern& active : patterns) {
        if (active.pattern->detector == DetectorKind::Generic) return false;
        if (active.pattern->length < 4) return false;
    }
    return true;
}

bool pattern_possible(const Pattern& pattern, int n, int k) {
    if (pattern.length > n) return false;
    if (pattern.rank > k) return false;
    // A word of length n using k letters has n-k repeated positions in total.
    // An occurrence of this pattern needs at least length-rank repeated positions.
    if (pattern.defect > n - k) return false;
    return true;
}

int automatic_split_depth(int n, int k, int threads) {
    if (n == 0 || k <= 1) return 0;
    const std::uint64_t target = static_cast<std::uint64_t>(std::max(1, threads)) * 64ULL;
    std::uint64_t tasks = 1;
    int depth = 0;
    while (depth < n && tasks < target) {
        if (tasks > MAX_PREFIX_TASKS / static_cast<std::uint64_t>(k)) break;
        tasks *= static_cast<std::uint64_t>(k);
        ++depth;
    }
    return depth;
}

std::uint64_t integer_power_checked(int base, int exponent) {
    std::uint64_t answer = 1;
    for (int i = 0; i < exponent; ++i) {
        if (answer > MAX_PREFIX_TASKS / static_cast<std::uint64_t>(base))
            fail("requested split depth creates more than "
                 + std::to_string(MAX_PREFIX_TASKS)
                 + " prefix tasks; reduce --split-depth");
        answer *= static_cast<std::uint64_t>(base);
    }
    return answer;
}

FixedResult enumerate_fixed(int n,
                            int k,
                            int requested_split_depth,
                            int threads,
                            EngineChoice engine_choice,
                            const std::vector<AvoidanceClass>& classes,
                            const std::vector<Pattern>& patterns,
                            const std::vector<StatisticSpec>& statistics = {},
                            const std::string& catalog_dir = {}) {
    FixedResult result;
    result.n = n;
    result.k = k;
    result.cayley_words = cayley_words(n, k);
    result.avoiders.assign(classes.size(), 0);
    result.statistic_counts.resize(classes.size() * statistics.size());
    const auto start = std::chrono::steady_clock::now();
    const bool catalog_enabled = !catalog_dir.empty();
    const bool analysis_enabled = catalog_enabled || !statistics.empty();

    std::unique_ptr<CatalogWriter> catalog_writer;
    if (catalog_enabled)
        catalog_writer = std::make_unique<CatalogWriter>(catalog_dir, n, k, classes.size());

    const ClassMask all_classes = classes.size() == MAX_CLASSES
        ? ~ClassMask{0}
        : (ClassMask{1} << classes.size()) - 1;

    ClassMask possible_classes = 0;
    for (std::size_t class_index = 0; class_index < classes.size(); ++class_index) {
        bool any_possible = false;
        for (int pattern_id : classes[class_index].pattern_ids) {
            if (pattern_possible(patterns[static_cast<std::size_t>(pattern_id)], n, k)) {
                any_possible = true;
                break;
            }
        }
        if (any_possible) {
            possible_classes |= ClassMask{1} << class_index;
        } else if (!analysis_enabled) {
            // In pure count-only mode these classes can be filled analytically.
            result.avoiders[class_index] = result.cayley_words;
        }
    }

    if (result.cayley_words == 0 || (!analysis_enabled && possible_classes == 0)) {
        if (catalog_writer) catalog_writer->finish();
        result.seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        return result;
    }

    // Catalogue/statistics modes visit every relevant word; pure count-only mode may use analytic shortcuts.
    const ClassMask initial_alive = analysis_enabled ? all_classes : possible_classes;

    SearchContext context;
    context.n = n;
    context.k = k;
    context.statistics = &statistics;
    for (const Pattern& pattern : patterns) {
        const ClassMask affected = pattern.class_mask & initial_alive;
        if (affected != 0 && pattern_possible(pattern, n, k))
            context.patterns.push_back(ActivePattern{&pattern, affected});
    }
    std::stable_sort(context.patterns.begin(), context.patterns.end(),
        [](const ActivePattern& a, const ActivePattern& b) {
            if (a.pattern->length != b.pattern->length)
                return a.pattern->length < b.pattern->length;
            const int a_coverage = std::popcount(a.class_mask);
            const int b_coverage = std::popcount(b.class_mask);
            if (a_coverage != b_coverage) return a_coverage > b_coverage;
            return a.pattern->display < b.pattern->display;
        });

    const bool leaf_mode = engine_choice == EngineChoice::Leaf
        || (engine_choice == EngineChoice::Auto && automatic_leaf_engine(context.patterns));
    result.engine = leaf_mode ? "leaf" : "prefix";

    const int split_depth = requested_split_depth < 0
        ? automatic_split_depth(n, k, threads)
        : std::min(requested_split_depth, n);
    const std::uint64_t task_count = split_depth == 0
        ? 1 : integer_power_checked(k, split_depth);
    result.split_depth = split_depth;
    result.prefix_tasks = task_count;

    const int allocated_threads = portable_threads::effective_thread_count(threads, task_count);
    std::vector<ThreadAccumulator> local;
    local.reserve(static_cast<std::size_t>(allocated_threads));
    for (int i = 0; i < allocated_threads; ++i)
        local.emplace_back(classes.size(), catalog_enabled, statistics.size());

    portable_threads::parallel_for_dynamic(task_count, allocated_threads,
        [&](std::uint64_t task_code, int tid) {
        ThreadAccumulator& accumulator = local[static_cast<std::size_t>(tid)];
        std::array<std::uint8_t, MAX_N> word{};
        std::array<std::uint8_t, MAX_N> before{};
        std::uint64_t code = task_code;
        for (int position = split_depth - 1; position >= 0; --position) {
            word[static_cast<std::size_t>(position)] =
                static_cast<std::uint8_t>(code % static_cast<std::uint64_t>(k));
            code /= static_cast<std::uint64_t>(k);
        }

        LetterMask used = 0;
        bool abandoned = false;
        if (leaf_mode) {
            for (int position = 0; position < split_depth; ++position) {
                const int letter = word[static_cast<std::size_t>(position)];
                used |= LetterMask{1} << letter;
                const int missing = k - std::popcount(used);
                if (missing > n - (position + 1)) {
                    abandoned = true;
                    break;
                }
            }
            if (!abandoned)
                enumerate_suffix_leaf(split_depth, used, initial_alive, word,
                                      context, accumulator, catalog_writer.get());
        } else {
            ClassMask alive = initial_alive;
            for (int position = 0; position < split_depth; ++position) {
                before[static_cast<std::size_t>(position)] = position == 0
                    ? std::numeric_limits<std::uint8_t>::max()
                    : std::min(before[static_cast<std::size_t>(position - 1)],
                               word[static_cast<std::size_t>(position - 1)]);
                const int letter = word[static_cast<std::size_t>(position)];
                used |= LetterMask{1} << letter;
                alive = update_alive(alive, word, before, position + 1, context.patterns);
                const int missing = k - std::popcount(used);
                if (alive == 0 || missing > n - (position + 1)) {
                    abandoned = true;
                    break;
                }
            }
            if (!abandoned)
                enumerate_suffix(split_depth, used, alive, word, before,
                                 context, accumulator, catalog_writer.get());
        }
    });

    if (catalog_writer) {
        for (ThreadAccumulator& accumulator : local) {
            for (std::size_t class_index = 0; class_index < classes.size(); ++class_index)
                catalog_writer->flush(class_index, accumulator.catalog_buffers[class_index]);
        }
        catalog_writer->finish();
    }

    for (const ThreadAccumulator& accumulator : local) {
        result.search_nodes += accumulator.search_nodes;
        result.surviving_leaves += accumulator.surviving_leaves;
        for (std::size_t class_index = 0; class_index < classes.size(); ++class_index)
            result.avoiders[class_index] += accumulator.avoiders[class_index];
        for (std::size_t index = 0; index < accumulator.statistic_counts.size(); ++index)
            for (const auto& [key, value] : accumulator.statistic_counts[index]) result.statistic_counts[index][key] += value;
    }

    for (std::size_t class_index = 0; class_index < classes.size(); ++class_index) {
        if (!analysis_enabled && (possible_classes & (ClassMask{1} << class_index)) == 0)
            continue; // already set analytically above
        if (result.avoiders[class_index] > result.cayley_words)
            fail("internal counting error: avoider count exceeds total Cayley words");
    }

    result.seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}


struct RGFPrefixTask {
    std::array<std::uint8_t, MAX_N> word{};
    std::array<std::uint8_t, MAX_N> before{};
    int depth = 0;
    int current_max = -1; // zero-based; -1 at the empty prefix
    ClassMask alive = 0;
};

bool rgf_completion_possible(int position, int current_max, int n, int k) {
    const int used_labels = position == 0 ? 0 : current_max + 1;
    if (used_labels > k) return false;
    return k - used_labels <= n - position;
}

void enumerate_rgf_suffix(int position,
                          int current_max,
                          ClassMask alive,
                          std::array<std::uint8_t, MAX_N>& word,
                          std::array<std::uint8_t, MAX_N>& before,
                          const SearchContext& context,
                          ThreadAccumulator& accumulator,
                          CatalogWriter* catalog_writer) {
    ++accumulator.search_nodes;
    if (alive == 0 || !rgf_completion_possible(position, current_max, context.n, context.k))
        return;

    if (position == context.n) {
        if ((position == 0 ? 0 : current_max + 1) != context.k) return;
        ++accumulator.surviving_leaves;
        record_alive_leaf(alive, word, context, accumulator, catalog_writer);
        return;
    }
    if (position < 0 || position >= MAX_N)
        fail("internal RGF prefix position is outside the word buffer");

    before[static_cast<std::size_t>(position)] = position == 0
        ? std::numeric_limits<std::uint8_t>::max()
        : std::min(before[static_cast<std::size_t>(position - 1)],
                   word[static_cast<std::size_t>(position - 1)]);

    const int largest_next = position == 0
        ? 0
        : std::min(current_max + 1, context.k - 1);
    for (int letter = 0; letter <= largest_next; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        const int next_max = std::max(current_max, letter);
        if (!rgf_completion_possible(position + 1, next_max, context.n, context.k))
            continue;
        const ClassMask next_alive = update_alive(
            alive, word, before, position + 1, context.patterns);
        enumerate_rgf_suffix(position + 1, next_max, next_alive,
                             word, before, context, accumulator, catalog_writer);
    }
}

void enumerate_rgf_suffix_leaf(int position,
                               int current_max,
                               ClassMask initial_alive,
                               std::array<std::uint8_t, MAX_N>& word,
                               const SearchContext& context,
                               ThreadAccumulator& accumulator,
                               CatalogWriter* catalog_writer) {
    ++accumulator.search_nodes;
    if (!rgf_completion_possible(position, current_max, context.n, context.k)) return;

    if (position == context.n) {
        if ((position == 0 ? 0 : current_max + 1) != context.k) return;
        ClassMask alive = initial_alive;
        for (const ActivePattern& active : context.patterns) {
            if ((alive & active.class_mask) == 0) continue;
            if (contains_full(*active.pattern, word, context.n)) {
                alive &= ~active.class_mask;
                if (alive == 0) break;
            }
        }
        if (alive != 0) {
            ++accumulator.surviving_leaves;
            record_alive_leaf(alive, word, context, accumulator, catalog_writer);
        }
        return;
    }
    if (position < 0 || position >= MAX_N)
        fail("internal RGF leaf position is outside the word buffer");

    const int largest_next = position == 0
        ? 0
        : std::min(current_max + 1, context.k - 1);
    for (int letter = 0; letter <= largest_next; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        const int next_max = std::max(current_max, letter);
        if (!rgf_completion_possible(position + 1, next_max, context.n, context.k))
            continue;
        enumerate_rgf_suffix_leaf(position + 1, next_max, initial_alive,
                                  word, context, accumulator, catalog_writer);
    }
}

std::vector<RGFPrefixTask> make_rgf_frontier(int n,
                                              int k,
                                              int requested_split_depth,
                                              int threads,
                                              bool leaf_mode,
                                              ClassMask initial_alive,
                                              const SearchContext& context,
                                              int& actual_depth) {
    std::vector<RGFPrefixTask> frontier(1);
    frontier[0].alive = initial_alive;
    actual_depth = 0;
    const int requested_depth = requested_split_depth < 0
        ? n : std::min(requested_split_depth, n);
    const std::uint64_t target = static_cast<std::uint64_t>(std::max(1, threads)) * 64ULL;

    while (actual_depth < requested_depth) {
        if (requested_split_depth < 0 && actual_depth > 0
            && frontier.size() >= target) break;

        std::vector<RGFPrefixTask> next;
        next.reserve(std::min<std::size_t>(
            MAX_PREFIX_TASKS,
            std::max<std::size_t>(frontier.size(), frontier.size() * 2)));

        for (const RGFPrefixTask& task : frontier) {
            const int position = task.depth;
            if (position >= n) {
                next.push_back(task);
                continue;
            }
            const int largest_next = position == 0
                ? 0
                : std::min(task.current_max + 1, k - 1);
            for (int letter = 0; letter <= largest_next; ++letter) {
                RGFPrefixTask child = task;
                child.word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
                child.before[static_cast<std::size_t>(position)] = position == 0
                    ? std::numeric_limits<std::uint8_t>::max()
                    : std::min(child.before[static_cast<std::size_t>(position - 1)],
                               child.word[static_cast<std::size_t>(position - 1)]);
                child.current_max = std::max(task.current_max, letter);
                child.depth = position + 1;
                if (!rgf_completion_possible(child.depth, child.current_max, n, k))
                    continue;
                if (!leaf_mode) {
                    child.alive = update_alive(task.alive, child.word, child.before,
                                               child.depth, context.patterns);
                    if (child.alive == 0) continue;
                }
                next.push_back(std::move(child));
                if (next.size() > MAX_PREFIX_TASKS)
                    fail("requested RGF split depth creates more than "
                         + std::to_string(MAX_PREFIX_TASKS)
                         + " viable prefix tasks; reduce --split-depth");
            }
        }
        frontier = std::move(next);
        ++actual_depth;
        if (frontier.empty()) break;
    }
    return frontier;
}

FixedResult enumerate_fixed_rgf(int n,
                                int k,
                                int requested_split_depth,
                                int threads,
                                EngineChoice engine_choice,
                                const std::vector<AvoidanceClass>& classes,
                                const std::vector<Pattern>& patterns,
                                const std::vector<StatisticSpec>& statistics = {},
                                const std::string& catalog_dir = {}) {
    FixedResult result;
    result.n = n;
    result.k = k;
    result.cayley_words = rgf_words(n, k);
    result.avoiders.assign(classes.size(), 0);
    result.statistic_counts.resize(classes.size() * statistics.size());
    const auto start = std::chrono::steady_clock::now();
    const bool catalog_enabled = !catalog_dir.empty();
    const bool analysis_enabled = catalog_enabled || !statistics.empty();

    std::unique_ptr<CatalogWriter> catalog_writer;
    if (catalog_enabled)
        catalog_writer = std::make_unique<CatalogWriter>(catalog_dir, n, k, classes.size());

    const ClassMask all_classes = classes.size() == MAX_CLASSES
        ? ~ClassMask{0}
        : (ClassMask{1} << classes.size()) - 1;

    ClassMask possible_classes = 0;
    for (std::size_t class_index = 0; class_index < classes.size(); ++class_index) {
        bool any_possible = false;
        for (int pattern_id : classes[class_index].pattern_ids) {
            if (pattern_possible(patterns[static_cast<std::size_t>(pattern_id)], n, k)) {
                any_possible = true;
                break;
            }
        }
        if (any_possible) {
            possible_classes |= ClassMask{1} << class_index;
        } else if (!analysis_enabled) {
            result.avoiders[class_index] = result.cayley_words;
        }
    }

    if (result.cayley_words == 0 || (!analysis_enabled && possible_classes == 0)) {
        if (catalog_writer) catalog_writer->finish();
        result.seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        return result;
    }

    const ClassMask initial_alive = analysis_enabled ? all_classes : possible_classes;
    SearchContext context;
    context.n = n;
    context.k = k;
    context.statistics = &statistics;
    for (const Pattern& pattern : patterns) {
        const ClassMask affected = pattern.class_mask & initial_alive;
        if (affected != 0 && pattern_possible(pattern, n, k))
            context.patterns.push_back(ActivePattern{&pattern, affected});
    }
    std::stable_sort(context.patterns.begin(), context.patterns.end(),
        [](const ActivePattern& a, const ActivePattern& b) {
            if (a.pattern->length != b.pattern->length)
                return a.pattern->length < b.pattern->length;
            const int a_coverage = std::popcount(a.class_mask);
            const int b_coverage = std::popcount(b.class_mask);
            if (a_coverage != b_coverage) return a_coverage > b_coverage;
            return a.pattern->display < b.pattern->display;
        });

    const bool leaf_mode = engine_choice == EngineChoice::Leaf
        || (engine_choice == EngineChoice::Auto && automatic_leaf_engine(context.patterns));
    result.engine = leaf_mode ? "rgf-leaf" : "rgf-prefix";

    int split_depth = 0;
    std::vector<RGFPrefixTask> frontier = make_rgf_frontier(
        n, k, requested_split_depth, threads, leaf_mode,
        initial_alive, context, split_depth);
    result.split_depth = split_depth;
    result.prefix_tasks = static_cast<std::uint64_t>(frontier.size());

    if (frontier.empty()) {
        if (catalog_writer) catalog_writer->finish();
        result.seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        return result;
    }

    const int allocated_threads = portable_threads::effective_thread_count(
        threads, static_cast<std::uint64_t>(frontier.size()));
    std::vector<ThreadAccumulator> local;
    local.reserve(static_cast<std::size_t>(allocated_threads));
    for (int i = 0; i < allocated_threads; ++i)
        local.emplace_back(classes.size(), catalog_enabled, statistics.size());

    portable_threads::parallel_for_dynamic(
        static_cast<std::uint64_t>(frontier.size()), allocated_threads,
        [&](std::uint64_t task_index, int tid) {
            ThreadAccumulator& accumulator = local[static_cast<std::size_t>(tid)];
            RGFPrefixTask task = frontier[static_cast<std::size_t>(task_index)];
            if (leaf_mode) {
                enumerate_rgf_suffix_leaf(task.depth, task.current_max, initial_alive,
                                          task.word, context, accumulator,
                                          catalog_writer.get());
            } else {
                enumerate_rgf_suffix(task.depth, task.current_max, task.alive,
                                     task.word, task.before, context, accumulator,
                                     catalog_writer.get());
            }
        });

    if (catalog_writer) {
        for (ThreadAccumulator& accumulator : local) {
            for (std::size_t class_index = 0; class_index < classes.size(); ++class_index)
                catalog_writer->flush(class_index, accumulator.catalog_buffers[class_index]);
        }
        catalog_writer->finish();
    }

    for (const ThreadAccumulator& accumulator : local) {
        result.search_nodes += accumulator.search_nodes;
        result.surviving_leaves += accumulator.surviving_leaves;
        for (std::size_t class_index = 0; class_index < classes.size(); ++class_index)
            result.avoiders[class_index] += accumulator.avoiders[class_index];
        for (std::size_t index = 0; index < accumulator.statistic_counts.size(); ++index)
            for (const auto& [key, value] : accumulator.statistic_counts[index])
                result.statistic_counts[index][key] += value;
    }

    for (std::size_t class_index = 0; class_index < classes.size(); ++class_index) {
        if (!analysis_enabled && (possible_classes & (ClassMask{1} << class_index)) == 0)
            continue;
        if (result.avoiders[class_index] > result.cayley_words)
            fail("internal RGF counting error: avoider count exceeds total RGFs");
    }

    result.seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}


struct ListingState {
    std::uint64_t offset = 0;
    std::uint64_t limit = 100; // zero means unlimited
    std::uint64_t seen = 0;
    std::uint64_t emitted = 0;
    bool done = false;
    std::ostream* output = nullptr;
};

void list_suffix(int position,
                 LetterMask used,
                 std::array<std::uint8_t, MAX_N>& word,
                 std::array<std::uint8_t, MAX_N>& before,
                 int n,
                 int k,
                 const std::vector<const Pattern*>& forbidden,
                 ListingState& state) {
    if (state.done) return;
    const int remaining = n - position;
    const int missing = k - std::popcount(used);
    if (missing > remaining) return;

    if (position == n) {
        if (missing != 0) return;
        if (state.seen >= state.offset) {
            *state.output << format_word(word, n, k) << '\n';
            ++state.emitted;
            if (state.limit != 0 && state.emitted >= state.limit)
                state.done = true;
        }
        ++state.seen;
        return;
    }

    before[static_cast<std::size_t>(position)] = position == 0
        ? std::numeric_limits<std::uint8_t>::max()
        : std::min(before[static_cast<std::size_t>(position - 1)],
                   word[static_cast<std::size_t>(position - 1)]);

    for (int letter = 0; letter < k && !state.done; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        bool forbidden_now = false;
        for (const Pattern* pattern : forbidden) {
            if (position + 1 < pattern->length) continue;
            if (new_occurrence(*pattern, word, before, position + 1)) {
                forbidden_now = true;
                break;
            }
        }
        if (!forbidden_now) {
            list_suffix(position + 1,
                        used | (LetterMask{1} << letter),
                        word, before, n, k, forbidden, state);
        }
    }
}

void list_fixed_avoiders(int n,
                         int k,
                         const AvoidanceClass& cls,
                         const std::vector<Pattern>& patterns,
                         ListingState& state) {
    if (state.done || cayley_words(n, k) == 0) return;
    std::vector<const Pattern*> forbidden;
    for (int pattern_id : cls.pattern_ids) {
        const Pattern& pattern = patterns[static_cast<std::size_t>(pattern_id)];
        if (pattern_possible(pattern, n, k)) forbidden.push_back(&pattern);
    }
    std::stable_sort(forbidden.begin(), forbidden.end(),
        [](const Pattern* a, const Pattern* b) {
            if (a->length != b->length) return a->length < b->length;
            return a->display < b->display;
        });

    std::array<std::uint8_t, MAX_N> word{};
    std::array<std::uint8_t, MAX_N> before{};
    list_suffix(0, 0, word, before, n, k, forbidden, state);
}


void list_rgf_suffix(int position,
                     int current_max,
                     std::array<std::uint8_t, MAX_N>& word,
                     std::array<std::uint8_t, MAX_N>& before,
                     int n,
                     int k,
                     const std::vector<const Pattern*>& forbidden,
                     ListingState& state) {
    if (state.done || !rgf_completion_possible(position, current_max, n, k)) return;
    if (position == n) {
        if ((position == 0 ? 0 : current_max + 1) != k) return;
        if (state.seen >= state.offset) {
            *state.output << format_word(word, n, k) << '\n';
            ++state.emitted;
            if (state.limit != 0 && state.emitted >= state.limit) state.done = true;
        }
        ++state.seen;
        return;
    }

    before[static_cast<std::size_t>(position)] = position == 0
        ? std::numeric_limits<std::uint8_t>::max()
        : std::min(before[static_cast<std::size_t>(position - 1)],
                   word[static_cast<std::size_t>(position - 1)]);
    const int largest_next = position == 0 ? 0 : std::min(current_max + 1, k - 1);
    for (int letter = 0; letter <= largest_next && !state.done; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        const int next_max = std::max(current_max, letter);
        if (!rgf_completion_possible(position + 1, next_max, n, k)) continue;
        bool forbidden_now = false;
        for (const Pattern* pattern : forbidden) {
            if (position + 1 < pattern->length) continue;
            if (new_occurrence(*pattern, word, before, position + 1)) {
                forbidden_now = true;
                break;
            }
        }
        if (!forbidden_now)
            list_rgf_suffix(position + 1, next_max, word, before,
                            n, k, forbidden, state);
    }
}

void list_fixed_rgf_avoiders(int n,
                             int k,
                             const AvoidanceClass& cls,
                             const std::vector<Pattern>& patterns,
                             ListingState& state) {
    if (state.done || rgf_words(n, k) == 0) return;
    std::vector<const Pattern*> forbidden;
    for (int pattern_id : cls.pattern_ids) {
        const Pattern& pattern = patterns[static_cast<std::size_t>(pattern_id)];
        if (pattern_possible(pattern, n, k)) forbidden.push_back(&pattern);
    }
    std::stable_sort(forbidden.begin(), forbidden.end(),
        [](const Pattern* a, const Pattern* b) {
            if (a->length != b->length) return a->length < b->length;
            return a->display < b->display;
        });
    std::array<std::uint8_t, MAX_N> word{};
    std::array<std::uint8_t, MAX_N> before{};
    list_rgf_suffix(0, -1, word, before, n, k, forbidden, state);
}

std::uint64_t list_rgf_avoiders(int n,
                                int only_k,
                                const AvoidanceClass& cls,
                                const std::vector<Pattern>& patterns,
                                std::uint64_t offset,
                                std::uint64_t limit,
                                std::ostream& output) {
    ListingState state;
    state.offset = offset;
    state.limit = limit;
    state.output = &output;
    if (n == 0) {
        if (only_k == 0 && offset == 0 && (limit == 0 || limit > 0)) {
            output << "epsilon\n";
            state.emitted = 1;
        }
        state.seen = only_k == 0 ? 1 : 0;
        return state.emitted;
    }
    const int first_k = only_k == 0 ? 1 : only_k;
    const int last_k = only_k == 0 ? n : only_k;
    if (first_k <= n) {
        for (int k = first_k; k <= last_k && !state.done; ++k)
            list_fixed_rgf_avoiders(n, k, cls, patterns, state);
    }
    return state.emitted;
}

std::uint64_t list_avoiders(int n,
                            int only_k,
                            const AvoidanceClass& cls,
                            const std::vector<Pattern>& patterns,
                            std::uint64_t offset,
                            std::uint64_t limit,
                            std::ostream& output) {
    ListingState state;
    state.offset = offset;
    state.limit = limit;
    state.output = &output;

    if (n == 0) {
        if (only_k == 0) {
            if (offset == 0 && (limit == 0 || limit > 0)) {
                output << "epsilon\n";
                state.emitted = 1;
            }
            state.seen = 1;
        }
        return state.emitted;
    }

    const int first_k = only_k == 0 ? 1 : only_k;
    const int last_k = only_k == 0 ? n : only_k;
    if (first_k <= n) {
        for (int k = first_k; k <= last_k && !state.done; ++k)
            list_fixed_avoiders(n, k, cls, patterns, state);
    }
    return state.emitted;
}

int run_listing(const Options& opt, const ParsedInput& input) {
    if (opt.list_class < 1
        || opt.list_class > static_cast<int>(input.classes.size())) {
        fail("--list-class is outside the supplied class range 1,...,"
             + std::to_string(input.classes.size()));
    }
    std::ofstream output(native_path(opt.list_output), std::ios::binary | std::ios::trunc);
    if (!output) fail("cannot open listing output: " + opt.list_output);

    const AvoidanceClass& cls = input.classes[static_cast<std::size_t>(opt.list_class - 1)];
    const std::uint64_t emitted = opt.family == ObjectFamily::RGF
        ? list_rgf_avoiders(opt.list_n, opt.only_k, cls, input.patterns,
                            opt.list_offset, opt.list_limit, output)
        : list_avoiders(opt.list_n, opt.only_k, cls, input.patterns,
                        opt.list_offset, opt.list_limit, output);
    output.flush();
    if (!output) fail("failed while writing listing output: " + opt.list_output);

    std::cout << "Listed " << emitted << " avoiding "
              << (opt.family == ObjectFamily::RGF ? "RGF" : "Cayley permutation")
              << (emitted == 1 ? "" : "s")
              << " from " << cls.name << " at n=" << opt.list_n;
    if (opt.only_k > 0) std::cout << ", k=" << opt.only_k;
    std::cout << ", after offset " << opt.list_offset << ".\n"
              << "Wrote: " << opt.list_output << "\n";
    return 0;
}

std::vector<int> parse_word_values(const std::string& text){const std::string cleaned=lower_ascii(trim(text));if(cleaned=="epsilon"||cleaned=="empty")return {};return parse_positive_sequence(text,"word",true);}
std::string format_integer_word(const std::vector<int>& values){if(values.empty())return"epsilon";const int largest=*std::max_element(values.begin(),values.end());std::ostringstream out;bool spaced=largest>=10;for(std::size_t i=0;i<values.size();++i){if(spaced&&i)out<<' ';out<<values[i];}return out.str();}
bool occurrence_candidate_compatible(const Pattern& pattern,int pattern_position,int candidate,const std::array<int,MAX_N>& chosen_values){for(int earlier=0;earlier<pattern_position;++earlier){const int relation=pattern.relation[static_cast<std::size_t>(earlier*pattern.length+pattern_position)];const int earlier_value=chosen_values[static_cast<std::size_t>(earlier)];if(relation<0&&!(earlier_value<candidate))return false;if(relation>0&&!(earlier_value>candidate))return false;if(relation==0&&earlier_value!=candidate)return false;}return true;}
struct OccurrenceCollection{std::uint64_t total=0,limit=0;std::vector<std::vector<int>> positions;};
void collect_occurrences_rec(const Pattern& pattern,const std::vector<int>& word,int pattern_position,int next_index,std::array<int,MAX_N>& chosen_values,std::array<int,MAX_N>& chosen_indices,OccurrenceCollection& result){
 if(pattern_position==pattern.length){++result.total;if(result.limit==0||result.positions.size()<result.limit){std::vector<int> occurrence;for(int i=0;i<pattern.length;++i)occurrence.push_back(chosen_indices[static_cast<std::size_t>(i)]+1);result.positions.push_back(std::move(occurrence));}return;}
 const int n=static_cast<int>(word.size());int first=next_index,last=n-(pattern.length-pattern_position);if(pattern_position>0&&pattern.bonds[static_cast<std::size_t>(pattern_position-1)]){first=chosen_indices[static_cast<std::size_t>(pattern_position-1)]+1;last=first;}if(first<0||first>last||last>=n)return;
 for(int index=first;index<=last;++index){const int candidate=word[static_cast<std::size_t>(index)];if(!occurrence_candidate_compatible(pattern,pattern_position,candidate,chosen_values))continue;chosen_values[static_cast<std::size_t>(pattern_position)]=candidate;chosen_indices[static_cast<std::size_t>(pattern_position)]=index;collect_occurrences_rec(pattern,word,pattern_position+1,index+1,chosen_values,chosen_indices,result);if(pattern_position>0&&pattern.bonds[static_cast<std::size_t>(pattern_position-1)])break;}
}
OccurrenceCollection collect_occurrences(const Pattern& pattern,const std::vector<int>& word,std::uint64_t limit){OccurrenceCollection result;result.limit=limit;if(pattern.length>static_cast<int>(word.size()))return result;std::array<int,MAX_N> values{},indices{};collect_occurrences_rec(pattern,word,0,0,values,indices,result);return result;}
std::uint64_t count_occurrences(const Pattern& pattern,const std::array<std::uint8_t,MAX_N>& word,int n){std::vector<int> values;for(int i=0;i<n;++i)values.push_back(static_cast<int>(word[static_cast<std::size_t>(i)])+1);return collect_occurrences(pattern,values,1).total;}
std::string join_integer_vector(const std::vector<int>& values,char separator=' '){std::ostringstream out;for(std::size_t i=0;i<values.size();++i){if(i)out<<separator;out<<values[i];}return out.str();}
int run_inspection(const Options& opt){const auto word=parse_word_values(opt.inspect_word);const Pattern pattern=parse_single_pattern(opt.inspect_pattern);const auto occurrences=collect_occurrences(pattern,word,opt.inspect_limit);const std::string summary_path=opt.inspect_output_prefix+"_summary.csv",occurrences_path=opt.inspect_output_prefix+"_occurrences.csv";std::ofstream summary(native_path(summary_path)),output(native_path(occurrences_path));if(!summary||!output)fail("cannot open inspection output");summary<<"word,pattern,pattern_type,contains,total_occurrences,listed_occurrences\n"<<csv_cell(format_integer_word(word))<<','<<csv_cell(pattern.display)<<','<<pattern_type_name(pattern.type)<<','<<(occurrences.total>0?"true":"false")<<','<<occurrences.total<<','<<occurrences.positions.size()<<'\n';output<<"occurrence,positions,values\n";for(std::size_t index=0;index<occurrences.positions.size();++index){std::vector<int> selected;for(int position:occurrences.positions[index])selected.push_back(word[static_cast<std::size_t>(position-1)]);output<<(index+1)<<','<<csv_cell(join_integer_vector(occurrences.positions[index]))<<','<<csv_cell(join_integer_vector(selected))<<'\n';}std::cout<<"Word: "<<format_integer_word(word)<<"\nPattern: "<<pattern.display<<" ("<<pattern_type_name(pattern.type)<<")\nOccurrences: "<<occurrences.total<<"\nWrote:\n  "<<summary_path<<"\n  "<<occurrences_path<<"\n";return 0;}

struct QueryThreadAccumulator{std::unordered_map<std::uint64_t,Count> distribution;Count search_nodes=0,avoiders=0;};
struct QueryFixedResult{int n=0,k=0;Count avoiders=0,search_nodes=0;std::unordered_map<std::uint64_t,Count> distribution;double seconds=0;};
void query_suffix(int position,LetterMask used,std::array<std::uint8_t,MAX_N>& word,std::array<std::uint8_t,MAX_N>& before,int n,int k,const std::vector<const Pattern*>& forbidden,const Pattern& query_pattern,QueryThreadAccumulator& accumulator){++accumulator.search_nodes;const int remaining=n-position,missing=k-std::popcount(used);if(missing>remaining)return;if(position==n){if(missing)return;const auto occurrences=count_occurrences(query_pattern,word,n);++accumulator.distribution[occurrences];++accumulator.avoiders;return;}before[static_cast<std::size_t>(position)]=position==0?std::numeric_limits<std::uint8_t>::max():std::min(before[static_cast<std::size_t>(position-1)],word[static_cast<std::size_t>(position-1)]);for(int letter=0;letter<k;++letter){word[static_cast<std::size_t>(position)]=static_cast<std::uint8_t>(letter);bool bad=false;for(const Pattern* pattern:forbidden)if(position+1>=pattern->length&&new_occurrence(*pattern,word,before,position+1)){bad=true;break;}if(!bad)query_suffix(position+1,used|(LetterMask{1}<<letter),word,before,n,k,forbidden,query_pattern,accumulator);}}
QueryFixedResult query_fixed_distribution(int n,
                                             int k,
                                             int requested_split_depth,
                                             int threads,
                                             const AvoidanceClass& cls,
                                             const std::vector<Pattern>& patterns,
                                             const Pattern& query_pattern) {
    QueryFixedResult result;
    result.n = n;
    result.k = k;
    const auto start = std::chrono::steady_clock::now();
    if (cayley_words(n, k) == 0) return result;

    std::vector<const Pattern*> forbidden;
    for (int id : cls.pattern_ids) {
        const Pattern& pattern = patterns[static_cast<std::size_t>(id)];
        if (pattern_possible(pattern, n, k)) forbidden.push_back(&pattern);
    }
    std::stable_sort(forbidden.begin(), forbidden.end(),
        [](const Pattern* a, const Pattern* b) {
            return a->length != b->length ? a->length < b->length : a->display < b->display;
        });

    const int split_depth = requested_split_depth < 0
        ? automatic_split_depth(n, k, threads)
        : std::min(requested_split_depth, n);
    const std::uint64_t task_count = split_depth == 0
        ? 1 : integer_power_checked(k, split_depth);
    const int allocated = portable_threads::effective_thread_count(threads, task_count);
    std::vector<QueryThreadAccumulator> local(static_cast<std::size_t>(allocated));

    portable_threads::parallel_for_dynamic(task_count, allocated,
        [&](std::uint64_t task_code, int tid) {
            auto& accumulator = local[static_cast<std::size_t>(tid)];
            std::array<std::uint8_t, MAX_N> word{}, before{};
            std::uint64_t code = task_code;
            for (int position = split_depth - 1; position >= 0; --position) {
                word[static_cast<std::size_t>(position)] =
                    static_cast<std::uint8_t>(code % static_cast<std::uint64_t>(k));
                code /= static_cast<std::uint64_t>(k);
            }
            LetterMask used = 0;
            bool abandoned = false;
            for (int position = 0; position < split_depth; ++position) {
                before[static_cast<std::size_t>(position)] = position == 0
                    ? std::numeric_limits<std::uint8_t>::max()
                    : std::min(before[static_cast<std::size_t>(position - 1)],
                               word[static_cast<std::size_t>(position - 1)]);
                const int letter = word[static_cast<std::size_t>(position)];
                used |= LetterMask{1} << letter;
                for (const Pattern* pattern : forbidden) {
                    if (position + 1 >= pattern->length
                        && new_occurrence(*pattern, word, before, position + 1)) {
                        abandoned = true;
                        break;
                    }
                }
                if (abandoned || k - std::popcount(used) > n - (position + 1)) {
                    abandoned = true;
                    break;
                }
            }
            if (!abandoned)
                query_suffix(split_depth, used, word, before, n, k,
                             forbidden, query_pattern, accumulator);
        });

    for (const auto& accumulator : local) {
        result.search_nodes += accumulator.search_nodes;
        result.avoiders += accumulator.avoiders;
        for (const auto& [occurrences, count] : accumulator.distribution)
            result.distribution[occurrences] += count;
    }
    result.seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

void query_rgf_suffix(int position,
                      int current_max,
                      std::array<std::uint8_t, MAX_N>& word,
                      std::array<std::uint8_t, MAX_N>& before,
                      int n,
                      int k,
                      const std::vector<const Pattern*>& forbidden,
                      const Pattern& query_pattern,
                      QueryThreadAccumulator& accumulator) {
    ++accumulator.search_nodes;
    if (!rgf_completion_possible(position, current_max, n, k)) return;
    if (position == n) {
        if ((position == 0 ? 0 : current_max + 1) != k) return;
        const auto occurrences = count_occurrences(query_pattern, word, n);
        ++accumulator.distribution[occurrences];
        ++accumulator.avoiders;
        return;
    }
    before[static_cast<std::size_t>(position)] = position == 0
        ? std::numeric_limits<std::uint8_t>::max()
        : std::min(before[static_cast<std::size_t>(position - 1)],
                   word[static_cast<std::size_t>(position - 1)]);
    const int largest_next = position == 0 ? 0 : std::min(current_max + 1, k - 1);
    for (int letter = 0; letter <= largest_next; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        const int next_max = std::max(current_max, letter);
        if (!rgf_completion_possible(position + 1, next_max, n, k)) continue;
        bool bad = false;
        for (const Pattern* pattern : forbidden) {
            if (position + 1 >= pattern->length
                && new_occurrence(*pattern, word, before, position + 1)) {
                bad = true;
                break;
            }
        }
        if (!bad)
            query_rgf_suffix(position + 1, next_max, word, before, n, k,
                             forbidden, query_pattern, accumulator);
    }
}

QueryFixedResult query_fixed_distribution_rgf(int n,
                                               int k,
                                               int requested_split_depth,
                                               int threads,
                                               const AvoidanceClass& cls,
                                               const std::vector<Pattern>& patterns,
                                               const Pattern& query_pattern) {
    QueryFixedResult result;
    result.n = n;
    result.k = k;
    const auto start = std::chrono::steady_clock::now();
    if (rgf_words(n, k) == 0) return result;

    std::vector<const Pattern*> forbidden;
    SearchContext context;
    context.n = n;
    context.k = k;
    for (int id : cls.pattern_ids) {
        const Pattern& pattern = patterns[static_cast<std::size_t>(id)];
        if (pattern_possible(pattern, n, k)) {
            forbidden.push_back(&pattern);
            context.patterns.push_back(ActivePattern{&pattern, ClassMask{1}});
        }
    }
    std::stable_sort(forbidden.begin(), forbidden.end(),
        [](const Pattern* a, const Pattern* b) {
            return a->length != b->length ? a->length < b->length : a->display < b->display;
        });
    std::stable_sort(context.patterns.begin(), context.patterns.end(),
        [](const ActivePattern& a, const ActivePattern& b) {
            return a.pattern->length != b.pattern->length
                ? a.pattern->length < b.pattern->length
                : a.pattern->display < b.pattern->display;
        });

    int split_depth = 0;
    std::vector<RGFPrefixTask> frontier = make_rgf_frontier(
        n, k, requested_split_depth, threads, false, ClassMask{1}, context, split_depth);
    if (frontier.empty()) return result;
    const int allocated = portable_threads::effective_thread_count(
        threads, static_cast<std::uint64_t>(frontier.size()));
    std::vector<QueryThreadAccumulator> local(static_cast<std::size_t>(allocated));
    portable_threads::parallel_for_dynamic(
        static_cast<std::uint64_t>(frontier.size()), allocated,
        [&](std::uint64_t task_index, int tid) {
            auto task = frontier[static_cast<std::size_t>(task_index)];
            query_rgf_suffix(task.depth, task.current_max, task.word, task.before,
                             n, k, forbidden, query_pattern,
                             local[static_cast<std::size_t>(tid)]);
        });
    for (const auto& accumulator : local) {
        result.search_nodes += accumulator.search_nodes;
        result.avoiders += accumulator.avoiders;
        for (const auto& [occurrences, count] : accumulator.distribution)
            result.distribution[occurrences] += count;
    }
    result.seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

void write_query_rows(std::ofstream& output,int n,const std::string& scope,int k,int class_index,const AvoidanceClass& cls,const Pattern& query_pattern,const std::unordered_map<std::uint64_t,Count>& distribution){std::vector<std::pair<std::uint64_t,Count>> rows(distribution.begin(),distribution.end());std::sort(rows.begin(),rows.end(),[](const auto&a,const auto&b){return a.first<b.first;});for(const auto&[occurrences,count]:rows)output<<n<<','<<scope<<','<<k<<','<<class_index<<','<<csv_cell(cls.name)<<','<<csv_cell(query_pattern.display)<<','<<pattern_type_name(query_pattern.type)<<','<<occurrences<<','<<count_to_string(count)<<'\n';output.flush();}
int run_pattern_query(const Options& opt, const ParsedInput& input) {
    if (opt.query_class < 1 || opt.query_class > static_cast<int>(input.classes.size()))
        fail("--query-class is outside the supplied class range");
    const auto& cls = input.classes[static_cast<std::size_t>(opt.query_class - 1)];
    const Pattern query_pattern = parse_single_pattern(opt.query_pattern);
    const int threads = opt.threads == 0
        ? portable_threads::hardware_thread_count() : opt.threads;
    std::ofstream output(native_path(opt.query_output));
    if (!output) fail("cannot open pattern-query output: " + opt.query_output);
    output << "n,scope,k,class_index,class_name,query_pattern,query_type,occurrences,count\n";
    std::unordered_map<std::uint64_t, Count> total;
    if (opt.query_n == 0) {
        if (opt.only_k == 0) total[0] = 1;
    } else {
        const int first = opt.only_k == 0 ? 1 : opt.only_k;
        const int last = opt.only_k == 0 ? opt.query_n : opt.only_k;
        if (first <= opt.query_n) {
            for (int k = first; k <= last; ++k) {
                const auto row = opt.family == ObjectFamily::RGF
                    ? query_fixed_distribution_rgf(opt.query_n, k, opt.split_depth,
                                                   threads, cls, input.patterns, query_pattern)
                    : query_fixed_distribution(opt.query_n, k, opt.split_depth,
                                               threads, cls, input.patterns, query_pattern);
                write_query_rows(output, opt.query_n, "exact", k, opt.query_class,
                                 cls, query_pattern, row.distribution);
                for (const auto& [occurrences, count] : row.distribution)
                    total[occurrences] += count;
                std::cout << "query family=" << family_name(opt.family)
                          << ", n=" << opt.query_n << ", k=" << k
                          << ", avoiders=" << count_to_string(row.avoiders)
                          << ", " << std::fixed << std::setprecision(3)
                          << row.seconds << " s\n";
            }
        }
    }
    write_query_rows(output, opt.query_n, "total", 0, opt.query_class,
                     cls, query_pattern, total);
    std::cout << "Occurrence distribution for " << query_pattern.display
              << " over " << cls.name << " in " << family_label(opt.family)
              << " at n=" << opt.query_n << "\nWrote: " << opt.query_output << "\n";
    return 0;
}

std::vector<int> standardize(const std::vector<std::uint8_t>& sample) {
    std::vector<int> result(sample.size(), 0);
    std::vector<int> distinct;
    for (std::uint8_t value : sample) distinct.push_back(value);
    std::sort(distinct.begin(), distinct.end());
    distinct.erase(std::unique(distinct.begin(), distinct.end()), distinct.end());
    for (std::size_t i = 0; i < sample.size(); ++i) {
        result[i] = static_cast<int>(
            std::lower_bound(distinct.begin(), distinct.end(), sample[i]) - distinct.begin()) + 1;
    }
    return result;
}

bool brute_contains_rec(const Pattern& pattern,
                        const std::array<std::uint8_t, MAX_N>& word,
                        int n,
                        int choose_position,
                        int previous_index,
                        std::vector<std::uint8_t>& sample) {
    if (choose_position == pattern.length)
        return standardize(sample) == pattern.values;

    const int still_needed = pattern.length - choose_position;
    int first_index = choose_position == 0 ? 0 : previous_index + 1;
    int last_index = n - still_needed;
    if (choose_position > 0
        && pattern.bonds[static_cast<std::size_t>(choose_position - 1)]) {
        first_index = previous_index + 1;
        last_index = first_index;
    }

    for (int index = first_index; index <= last_index && index < n; ++index) {
        sample[static_cast<std::size_t>(choose_position)] =
            word[static_cast<std::size_t>(index)];
        if (brute_contains_rec(pattern, word, n, choose_position + 1,
                               index, sample))
            return true;
    }
    return false;
}
bool brute_contains(const Pattern& pattern,
                    const std::array<std::uint8_t, MAX_N>& word,
                    int n) {
    if (n < pattern.length) return false;
    std::vector<std::uint8_t> sample(static_cast<std::size_t>(pattern.length));
    return brute_contains_rec(pattern, word, n, 0, -1, sample);
}

void detector_test_words(int position,
                         int n,
                         int alphabet,
                         std::array<std::uint8_t, MAX_N>& word,
                         const std::vector<Pattern>& patterns,
                         Count& checked) {
    if (position == n) {
        for (const Pattern& pattern : patterns) {
            bool incremental = false;
            std::array<std::uint8_t, MAX_N> before{};
            for (int length = 1; length <= n; ++length) {
                const int position = length - 1;
                before[static_cast<std::size_t>(position)] = position == 0
                    ? std::numeric_limits<std::uint8_t>::max()
                    : std::min(before[static_cast<std::size_t>(position - 1)],
                               word[static_cast<std::size_t>(position - 1)]);
                incremental = incremental || new_occurrence(pattern, word, before, length);
            }
            const bool full = contains_full(pattern, word, n);
            const bool brute = brute_contains(pattern, word, n);
            if (incremental != brute || full != brute) {
                std::ostringstream message;
                message << "detector mismatch for pattern " << pattern.display << " in word ";
                for (int i = 0; i < n; ++i)
                    message << (static_cast<int>(word[static_cast<std::size_t>(i)]) + 1);
                fail(message.str());
            }
        }
        ++checked;
        return;
    }
    for (int letter = 0; letter < alphabet; ++letter) {
        word[static_cast<std::size_t>(position)] = static_cast<std::uint8_t>(letter);
        detector_test_words(position + 1, n, alphabet, word, patterns, checked);
    }
}

ParsedInput parse_specs_for_test(const std::vector<std::string>& specs) {
    Options opt;
    opt.class_specs = specs;
    return parse_classes(opt);
}

void run_self_test() {
    std::cout << "Self-test 1/8: classical, consecutive, and vincular detectors...\n";
    std::vector<Pattern> patterns;
    for (const char* text : {
             "11", "12", "21", "121", "231", "13442", "14233",
             "consecutive:11", "consecutive:121", "vincular:121|1",
             "vincular:1232|2", "vincular:12321|1,3"})
        patterns.push_back(parse_single_pattern(text));
    Count checked = 0;
    std::array<std::uint8_t, MAX_N> word{};
    for (int alphabet = 1; alphabet <= 4; ++alphabet)
        for (int n = 0; n <= 7; ++n)
            detector_test_words(0, n, alphabet, word, patterns, checked);
    std::cout << "  checked " << count_to_string(checked)
              << " ordinary words against an independent brute-force detector\n";

    std::cout << "Self-test 2/8: exact formulas for Av(11), Av(12), and Av(21)...\n";
    ParsedInput small = parse_specs_for_test({"no_equal=11", "no_rise=12", "no_fall=21"});
    for (int n = 1; n <= 7; ++n) {
        std::vector<Count> totals(small.classes.size(), 0);
        for (int k = 1; k <= n; ++k) {
            const FixedResult row = enumerate_fixed(
                n, k, 2, 1, EngineChoice::Prefix, small.classes, small.patterns);
            for (std::size_t c = 0; c < totals.size(); ++c)
                totals[c] += row.avoiders[c];
        }
        const Count expected_no_equal = factorial(n);
        const Count expected_monotone = Count{1} << (n - 1);
        if (totals[0] != expected_no_equal || totals[1] != expected_monotone
            || totals[2] != expected_monotone)
            fail("small-class formula test failed at n=" + std::to_string(n));
    }
    std::cout << "  formulas verified through n=7\n";

    std::cout << "Self-test 3/8: generalized-pattern enumeration and occurrence counting...\n";
    ParsedInput generalized = parse_specs_for_test({
        "adjacent_equal=consecutive:11", "bonded_121=vincular:121|1"});
    std::vector<Count> generalized_totals(generalized.classes.size(), 0);
    for (int k = 1; k <= 3; ++k) {
        const FixedResult row = enumerate_fixed(
            3, k, 2, 1, EngineChoice::Prefix,
            generalized.classes, generalized.patterns);
        for (std::size_t c = 0; c < generalized_totals.size(); ++c)
            generalized_totals[c] += row.avoiders[c];
    }
    if (generalized_totals[0] != 8 || generalized_totals[1] != 12)
        fail("generalized-pattern enumeration test failed");
    const Pattern bonded_121 = parse_single_pattern("vincular:121|1");
    const auto occurrences = collect_occurrences(
        bonded_121, std::vector<int>{1,2,1,2,1}, 0);
    if (occurrences.total != 3)
        fail("generalized occurrence-count test failed");
    std::cout << "  verified Av(consecutive:11)[3]=8, Av(vincular:121|1)[3]=12,"
              << " and three bonded occurrences in 12121\n";

    std::cout << "Self-test 4/8: streamed statistic distributions...\n";
    ParsedInput all_words = parse_specs_for_test({"all=1234"});
    const std::vector<StatisticSpec> stats = {
        parse_statistic_spec("descents"),
        parse_statistic_spec("inversions"),
        parse_statistic_spec("descent_set")};
    std::vector<Distribution> merged(all_words.classes.size() * stats.size());
    for (int k = 1; k <= 3; ++k) {
        const FixedResult row = enumerate_fixed(
            3, k, 2, 1, EngineChoice::Prefix,
            all_words.classes, all_words.patterns, stats);
        for (std::size_t i = 0; i < row.statistic_counts.size(); ++i)
            for (const auto& [key, value] : row.statistic_counts[i])
                merged[i][key] += value;
    }
    const auto key_for = [](std::uint64_t order, const std::string& display) {
        return padded_unsigned(order) + static_cast<char>(0x1f) + display;
    };
    if (merged[0][key_for(0,"0")] != 4
        || merged[0][key_for(1,"1")] != 8
        || merged[0][key_for(2,"2")] != 1
        || merged[1][key_for(3,"3")] != 1
        || merged[2][key_for(0,"{}")] != 4
        || merged[2][key_for(3,"{1,2}")] != 1)
        fail("statistic-distribution test failed");
    std::cout << "  descent, inversion, and exact descent-set distributions verified at n=3\n";

    std::cout << "Self-test 5/8: published n=9, k=5 checkpoint...\n";
    ParsedInput pair = parse_specs_for_test({"A=13442", "B=14233"});
    const FixedResult checkpoint = enumerate_fixed(
        9, 5, -1, std::min(4, portable_threads::hardware_thread_count()), EngineChoice::Auto,
        pair.classes, pair.patterns);
    if (checkpoint.avoiders[0] != static_cast<Count>(742943)
        || checkpoint.avoiders[1] != static_cast<Count>(742944))
        fail("published checkpoint failed: obtained "
             + count_to_string(checkpoint.avoiders[0]) + " and "
             + count_to_string(checkpoint.avoiders[1]));
    std::cout << "  obtained 742943 and 742944\n";

    std::cout << "Self-test 6/8: deterministic paged avoider listing...\n";
    std::ostringstream listed;
    const std::uint64_t emitted = list_avoiders(
        3, 0, small.classes[0], small.patterns, 2, 2, listed);
    if (emitted != 2 || listed.str() != "213\n231\n")
        fail("paged listing test failed; obtained: " + listed.str());
    std::cout << "  offset and limit verified on Cayley Av(11) at n=3\n";

    std::cout << "Self-test 7/8: RGF growth rule and Stirling refinements...\n";
    ParsedInput rgf_all = parse_specs_for_test({"all_rgfs=123456789"});
    const std::vector<StatisticSpec> force_traversal = {parse_statistic_spec("descents")};
    const std::array<Count, 9> bell = {
        Count{1}, Count{1}, Count{2}, Count{5}, Count{15},
        Count{52}, Count{203}, Count{877}, Count{4140}};
    for (int n = 0; n <= 8; ++n) {
        Count total = 0;
        if (n == 0) {
            const FixedResult row = enumerate_fixed_rgf(
                0, 0, -1, 2, EngineChoice::Prefix,
                rgf_all.classes, rgf_all.patterns, force_traversal);
            if (row.avoiders[0] != 1) fail("RGF empty-word test failed");
            total = row.avoiders[0];
        } else {
            for (int k = 1; k <= n; ++k) {
                const FixedResult row = enumerate_fixed_rgf(
                    n, k, -1, 2, EngineChoice::Prefix,
                    rgf_all.classes, rgf_all.patterns, force_traversal);
                if (row.avoiders[0] != stirling_second(n, k))
                    fail("RGF Stirling refinement failed at n=" + std::to_string(n)
                         + ", k=" + std::to_string(k));
                total += row.avoiders[0];
            }
        }
        if (total != bell[static_cast<std::size_t>(n)])
            fail("RGF Bell-number test failed at n=" + std::to_string(n));
    }
    for (int n = 1; n <= 8; ++n) {
        std::vector<Count> totals(small.classes.size(), 0);
        for (int k = 1; k <= n; ++k) {
            const FixedResult row = enumerate_fixed_rgf(
                n, k, -1, 2, EngineChoice::Prefix,
                small.classes, small.patterns);
            for (std::size_t c = 0; c < totals.size(); ++c)
                totals[c] += row.avoiders[c];
        }
        if (totals[0] != 1 || totals[1] != 1
            || totals[2] != (Count{1} << (n - 1)))
            fail("RGF small-class formula test failed at n=" + std::to_string(n));
    }
    std::cout << "  Bell numbers, Stirling refinements, and Av(11), Av(12), Av(21) formulas verified through n=8\n";

    std::cout << "Self-test 8/8: RGF listing and occurrence distributions...\n";
    std::ostringstream rgf_listed;
    const std::uint64_t rgf_emitted = list_rgf_avoiders(
        4, 2, rgf_all.classes[0], rgf_all.patterns, 0, 0, rgf_listed);
    const std::string expected_rgfs =
        "1112\n1121\n1122\n1211\n1212\n1221\n1222\n";
    if (rgf_emitted != 7 || rgf_listed.str() != expected_rgfs)
        fail("RGF listing test failed; obtained: " + rgf_listed.str());
    const Pattern equal_pair = parse_single_pattern("11");
    std::unordered_map<std::uint64_t, Count> occurrence_distribution;
    for (int k = 1; k <= 3; ++k) {
        const auto row = query_fixed_distribution_rgf(
            3, k, -1, 2, rgf_all.classes[0], rgf_all.patterns, equal_pair);
        for (const auto& [occurrences_count, count] : row.distribution)
            occurrence_distribution[occurrences_count] += count;
    }
    if (occurrence_distribution[0] != 1
        || occurrence_distribution[1] != 3
        || occurrence_distribution[3] != 1
        || occurrence_distribution.size() != 3)
        fail("RGF occurrence-distribution test failed");
    std::cout << "  deterministic RGF listing and the 11-occurrence distribution at n=3 verified\nSelf-test passed.\n";
}
void merge_distributions(std::vector<Distribution>& target,
                         const std::vector<Distribution>& source) {
    if (target.size() != source.size()) fail("internal statistic-distribution size mismatch");
    for (std::size_t i = 0; i < source.size(); ++i)
        for (const auto& [key, count] : source[i]) target[i][key] += count;
}

void write_statistics_header(std::ofstream& out) {
    out << "n,scope,k,class_index,class_name,statistic,statistic_label,"
           "value,value_order,count\n";
    out.flush();
}

void write_statistics_rows(std::ofstream& out,
                           int n,
                           const std::string& scope,
                           int k,
                           const std::vector<AvoidanceClass>& classes,
                           const std::vector<StatisticSpec>& statistics,
                           const std::vector<Distribution>& distributions) {
    const std::size_t statistic_count = statistics.size();
    if (distributions.size() != classes.size() * statistic_count)
        fail("internal statistic output size mismatch");
    for (std::size_t class_index = 0; class_index < classes.size(); ++class_index) {
        for (std::size_t statistic_index = 0; statistic_index < statistic_count; ++statistic_index) {
            const Distribution& distribution =
                distributions[class_index * statistic_count + statistic_index];
            struct Row { std::string order; std::string display; Count count; };
            std::vector<Row> rows;
            rows.reserve(distribution.size());
            for (const auto& [encoded, count] : distribution) {
                const auto [order, display] = decode_statistic_value(encoded);
                rows.push_back(Row{order, display, count});
            }
            std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
                if (a.order != b.order) return a.order < b.order;
                return a.display < b.display;
            });
            for (const Row& row : rows) {
                out << n << ',' << scope << ',' << k << ',' << (class_index + 1)
                    << ',' << csv_cell(classes[class_index].name)
                    << ',' << statistics[statistic_index].id
                    << ',' << csv_cell(statistics[statistic_index].label)
                    << ',' << csv_cell(row.display)
                    << ',' << csv_cell(row.order)
                    << ',' << count_to_string(row.count) << '\n';
            }
        }
    }
    out.flush();
}

void write_metadata(const std::string& path,
                    const Options& opt,
                    int actual_threads,
                    const ParsedInput& input,
                    const std::vector<StatisticSpec>& statistics) {
    std::ofstream out(native_path(path));
    if (!out) fail("cannot open metadata output: " + path);
    out << "Pattern Engine 8 (native portable build)\n"
        << "Classical, consecutive, and vincular pattern containment; exact integer counts.\n\n"
        << "family = " << family_name(opt.family) << '\n'
        << "objects = " << family_label(opt.family) << '\n'
        << "min_n = " << opt.min_n << '\n'
        << "max_n = " << opt.max_n << '\n'
        << "only_k = " << opt.only_k << '\n'
        << "threads = " << actual_threads << '\n'
        << "engine = " << engine_name(opt.engine) << '\n'
        << "split_depth = "
        << (opt.split_depth < 0 ? "automatic" : std::to_string(opt.split_depth)) << '\n'
        << "catalog_dir = " << (opt.catalog_dir.empty() ? "disabled" : opt.catalog_dir)
        << "\n\nClasses:\n";
    for (std::size_t i = 0; i < input.classes.size(); ++i) {
        out << "  " << (i + 1) << ". " << input.classes[i].name
            << " = Av(" << input.classes[i].basis_display << ")"
            << " [CSV column: " << input.classes[i].column_name << "]\n";
    }
    out << "\nStatistics:";
    if (statistics.empty()) {
        out << " disabled\n";
    } else {
        out << '\n';
        for (const StatisticSpec& statistic : statistics)
            out << "  " << statistic.id << " = " << statistic.label << '\n';
    }
    out << "\nBuilt-in specialized detectors: classical 11, 12, 21, 13442, 14233.\n"
        << "All consecutive and vincular patterns, and all other valid classical patterns, "
           "use the exact generalized detector.\n";
}
void write_csv_header(std::ofstream& out,
                      bool by_max,
                      ObjectFamily family,
                      const std::vector<AvoidanceClass>& classes) {
    out << "n";
    if (by_max) out << ",k";
    out << ',' << family_total_column(family);
    for (const AvoidanceClass& cls : classes)
        out << ',' << csv_cell(cls.column_name);
    if (classes.size() == 2) out << ",difference_1_minus_2";
    if (by_max)
        out << ",engine,search_nodes,surviving_leaves,prefix_tasks,split_depth";
    out << ",seconds\n";
    out.flush();
}

void write_fixed_csv_row(std::ofstream& out,
                         const FixedResult& row,
                         const std::vector<AvoidanceClass>& classes) {
    out << row.n << ',' << row.k << ',' << count_to_string(row.cayley_words);
    for (Count value : row.avoiders) out << ',' << count_to_string(value);
    if (classes.size() == 2)
        out << ',' << signed_difference(row.avoiders[0], row.avoiders[1]);
    out << ',' << row.engine
        << ',' << count_to_string(row.search_nodes)
        << ',' << count_to_string(row.surviving_leaves)
        << ',' << row.prefix_tasks
        << ',' << row.split_depth
        << ',' << std::setprecision(12) << row.seconds << '\n';
    out.flush();
}

void write_total_csv_row(std::ofstream& out,
                         int n,
                         Count total_words,
                         const std::vector<Count>& totals,
                         double seconds,
                         const std::vector<AvoidanceClass>& classes) {
    out << n << ',' << count_to_string(total_words);
    for (Count value : totals) out << ',' << count_to_string(value);
    if (classes.size() == 2)
        out << ',' << signed_difference(totals[0], totals[1]);
    out << ',' << std::setprecision(12) << seconds << '\n';
    out.flush();
}

void print_class_list(const ParsedInput& input) {
    std::cout << "Avoidance classes:\n";
    for (std::size_t i = 0; i < input.classes.size(); ++i)
        std::cout << "  [" << (i + 1) << "] " << input.classes[i].name
                  << " = Av(" << input.classes[i].basis_display << ")\n";
    std::cout << '\n';
}

void print_fixed_progress(const FixedResult& row,
                          ObjectFamily family,
                          const std::vector<AvoidanceClass>& classes) {
    std::cout << "n=" << row.n << ", k=" << row.k
              << ", " << family_short_label(family) << '='
              << count_to_string(row.cayley_words);
    for (std::size_t c = 0; c < classes.size(); ++c)
        std::cout << ", " << classes[c].column_name << '='
                  << count_to_string(row.avoiders[c]);
    if (classes.size() == 2)
        std::cout << ", diff=" << signed_difference(row.avoiders[0], row.avoiders[1]);
    std::cout << ", " << std::fixed << std::setprecision(3)
              << row.seconds << " s";
    if (row.prefix_tasks > 0)
        std::cout << " [" << row.engine << ", depth " << row.split_depth
                  << ", " << row.prefix_tasks << " tasks]";
    std::cout << '\n';
}

void print_total_summary(int n,
                         Count words,
                         const std::vector<Count>& totals,
                         double seconds,
                         ObjectFamily family,
                         const std::vector<AvoidanceClass>& classes) {
    std::cout << "TOTAL n=" << n << ": " << family_short_label(family)
              << '=' << count_to_string(words);
    for (std::size_t c = 0; c < classes.size(); ++c)
        std::cout << ", " << classes[c].column_name << '='
                  << count_to_string(totals[c]);
    if (classes.size() == 2)
        std::cout << ", diff=" << signed_difference(totals[0], totals[1]);
    std::cout << ", elapsed=" << std::fixed << std::setprecision(3)
              << seconds << " s\n\n";
}

int run(const Options& opt) {
    if (opt.self_test) {
        run_self_test();
        return 0;
    }
    if (opt.inspect_mode) return run_inspection(opt);

    const ParsedInput input = parse_classes(opt);
    if (opt.list_mode) return run_listing(opt, input);
    if (opt.query_mode) return run_pattern_query(opt, input);

    const std::vector<StatisticSpec> statistics = parse_statistics(opt);
    const int actual_threads = opt.threads == 0
        ? portable_threads::hardware_thread_count() : opt.threads;

    const std::string totals_path = opt.output_prefix + "_totals.csv";
    const std::string by_max_path = opt.output_prefix + "_by_max.csv";
    const std::string metadata_path = opt.output_prefix + "_metadata.txt";
    const std::string statistics_path = opt.output_prefix + "_statistics.csv";

    std::ofstream totals_csv(native_path(totals_path));
    std::ofstream by_max_csv(native_path(by_max_path));
    if (!totals_csv) fail("cannot open output: " + totals_path);
    if (!by_max_csv) fail("cannot open output: " + by_max_path);
    write_csv_header(totals_csv, false, opt.family, input.classes);
    write_csv_header(by_max_csv, true, opt.family, input.classes);

    std::ofstream statistics_csv;
    if (!statistics.empty()) {
        statistics_csv.open(native_path(statistics_path));
        if (!statistics_csv) fail("cannot open output: " + statistics_path);
        write_statistics_header(statistics_csv);
    }
    write_metadata(metadata_path, opt, actual_threads, input, statistics);

    std::cout << "Avoidance enumeration of " << family_label(opt.family)
              << " from n=" << opt.min_n << " through n=" << opt.max_n
              << " using " << actual_threads << " thread"
              << (actual_threads == 1 ? "" : "s") << ".\n";
    if (!statistics.empty())
        std::cout << "Streaming " << statistics.size()
                  << " selected statistic distribution"
                  << (statistics.size() == 1 ? "" : "s") << ".\n";
    print_class_list(input);

    for (int n = opt.min_n; n <= opt.max_n; ++n) {
        const auto n_start = std::chrono::steady_clock::now();
        Count total_words = 0;
        std::vector<Count> totals(input.classes.size(), 0);
        std::vector<Distribution> total_distributions(
            input.classes.size() * statistics.size());

        const int first_k = n == 0 ? 0 : (opt.only_k == 0 ? 1 : opt.only_k);
        const int last_k = n == 0 ? 0 : (opt.only_k == 0 ? n : opt.only_k);
        if ((n != 0 || opt.only_k == 0) && first_k <= n) {
            for (int k = first_k; k <= last_k; ++k) {
                const FixedResult row = opt.family == ObjectFamily::RGF
                    ? enumerate_fixed_rgf(n, k, opt.split_depth, actual_threads, opt.engine,
                                          input.classes, input.patterns, statistics, opt.catalog_dir)
                    : enumerate_fixed(n, k, opt.split_depth, actual_threads, opt.engine,
                                      input.classes, input.patterns, statistics, opt.catalog_dir);
                write_fixed_csv_row(by_max_csv, row, input.classes);
                total_words += row.cayley_words;
                for (std::size_t c = 0; c < totals.size(); ++c)
                    totals[c] += row.avoiders[c];
                if (!statistics.empty()) {
                    write_statistics_rows(statistics_csv, n, "exact", k,
                                          input.classes, statistics,
                                          row.statistic_counts);
                    merge_distributions(total_distributions, row.statistic_counts);
                }
                if (!opt.quiet) print_fixed_progress(row, opt.family, input.classes);
            }
        }

        const double n_seconds = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - n_start).count();
        write_total_csv_row(totals_csv, n, total_words, totals, n_seconds, input.classes);
        if (!statistics.empty())
            write_statistics_rows(statistics_csv, n, "total", 0,
                                  input.classes, statistics, total_distributions);
        print_total_summary(n, total_words, totals, n_seconds, opt.family, input.classes);
    }

    std::cout << "Wrote temporary run data:\n"
              << "  " << totals_path << "\n"
              << "  " << by_max_path << "\n"
              << "  " << metadata_path << "\n";
    if (!statistics.empty()) std::cout << "  " << statistics_path << "\n";
    if (!opt.catalog_dir.empty())
        std::cout << "Temporary avoider catalogues: " << opt.catalog_dir << "\n";
    return 0;
}

} // namespace cayley

int cayley_program_main(int argc, char** argv) {
    std::cout.setf(std::ios::unitbuf);
    std::cerr.setf(std::ios::unitbuf);
    try {
        const cayley::Options options = cayley::parse_options(argc, argv);
        return cayley::run(options);
    } catch (const std::exception& error) {
        std::cerr << "fatal: " << error.what() << '\n';
        return 1;
    }
}

#ifdef _WIN32
std::string utf8_from_wide(const wchar_t* value) {
    if (value == nullptr || *value == L'\0') return {};
    const int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                              nullptr, 0, nullptr, nullptr);
    if (required <= 0) throw std::runtime_error("could not convert a Windows command-line argument to UTF-8");
    std::string result(static_cast<std::size_t>(required), '\0');
    const int written = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                             result.data(), required, nullptr, nullptr);
    if (written != required)
        throw std::runtime_error("could not convert a Windows command-line argument to UTF-8");
    result.resize(static_cast<std::size_t>(required - 1));
    return result;
}

int wmain(int argc, wchar_t** wide_argv) {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    try {
        std::vector<std::string> storage;
        storage.reserve(static_cast<std::size_t>(argc));
        for (int i = 0; i < argc; ++i) storage.push_back(utf8_from_wide(wide_argv[i]));
        std::vector<char*> argv;
        argv.reserve(storage.size());
        for (std::string& value : storage) argv.push_back(value.data());
        return cayley_program_main(argc, argv.data());
    } catch (const std::exception& error) {
        std::cerr << "fatal: " << error.what() << '\n';
        return 1;
    }
}
#else
int main(int argc, char** argv) {
    return cayley_program_main(argc, argv);
}
#endif
