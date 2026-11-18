#include "vault_json.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdio>
#include <string>

namespace {

using namespace vault::json;
constexpr Limits limits{8192, 8};
Workspace<limits.max_bytes> workspace;
std::array<char, comparison_capacity(limits.max_bytes)> bytes;
int failed = 0;

void expect(bool ok, const char* reason) {
    if (!ok) {
        std::fprintf(stderr, "%s\n", reason);
        ++failed;
    }
}

DecodeResult parse(std::string_view raw) {
    return decode_object(raw, limits, workspace.view());
}

std::string compare(std::string_view raw) {
    const auto parsed = parse(raw);
    if (!parsed) {
        expect(false, "comparison fixture must decode");
        return {};
    }
    const auto encoded = comparison(parsed.value, limits.max_bytes, workspace.view(), bytes.data(),
                                    bytes.size());
    expect(static_cast<bool>(encoded), "comparison fixture must encode");
    return std::string(encoded.bytes);
}

void decoder_cases() {
    expect(parse(R"({"type":1,"\u0074ype":2})").error == Error::duplicate_key,
           "escape-equivalent root keys must be duplicates");
    expect(parse(R"({"ext":[{"\u0000":1,"\u0000":2}]})").error == Error::duplicate_key,
           "NUL in keys must be length-aware and checked at depth");
    const auto with_nul_keys = parse(R"({"\u0000x":1,"\u0000y":2})");
    expect(with_nul_keys && with_nul_keys.value.key_at(0) == std::string_view("\0x", 2) &&
           with_nul_keys.value.member_at(1).integer() == 2 &&
           !with_nul_keys.value.member_at(2),
           "length-aware keys must distinguish bytes after NUL");
    expect(parse("{\"a\":\"\xc0\x80\"}").error == Error::utf8, "overlong UTF-8 must fail");
    expect(parse(R"({"a":"\ud800"})").error == Error::syntax, "lone surrogate must fail");
    expect(parse(R"({"a":"\u0000"})").value.get("a").string() == std::string_view("\0", 1),
           "escaped NUL must survive");
    expect(parse(std::string_view("{}\0", 3)).error == Error::syntax, "raw NUL must fail");
    expect(parse("\xef\xbb\xbf{}").error == Error::syntax, "BOM must fail");
    expect(parse("{}true").error == Error::syntax, "second root must fail");
    expect(parse("[]").error == Error::root_type, "an object is required");
    expect(parse(R"({"s":"[[[[[[[[[[[[\"]]"})").error == Error::none,
           "brackets inside a quoted string must not consume depth");
    expect(parse(R"({"s":[[[[[[[0]]]]]]]})").error == Error::none, "depth 8 must decode");
    expect(parse(R"({"s":[[[[[[[[0]]]]]]]]})").error == Error::depth, "depth 9 must fail");

    std::string at_limit = "{}";
    at_limit.resize(limits.max_bytes, ' ');
    expect(static_cast<bool>(parse(at_limit)), "wire limit must decode");
    at_limit += ' ';
    expect(parse(at_limit).error == Error::size, "wire limit plus one must fail");

    auto view = workspace.view();
    --view.pool_size;
    expect(decode("{}", limits, view).error == Error::resource,
           "undersized pool must fail without fallback");
    std::array<yyjson_val*, limits.max_bytes / 5 + 1> external_keys{};
    view = workspace.view();
    view.keys = external_keys.data();
    view.key_count = 1;
    expect(decode("{}", limits, view).error == Error::resource, "undersized key scratch must fail");
    view.keys = nullptr;
    expect(decode("{}", limits, view).error == Error::resource, "null external scratch must fail");
    view.keys = external_keys.data();
    view.key_count = external_keys.size();
    const auto external = decode(R"({"z":0,"a":1})", limits, view);
    expect(external && static_cast<bool>(comparison(external.value, limits.max_bytes, view,
                                                   bytes.data(), bytes.size())),
           "separate key scratch remains compatible");
    expect(parse("{}").error == Error::none, "workspace must recover after failure");
}

void dense_arena_cases() {
    std::string array = "[0";
    for (std::size_t i = 1; i < 4095; ++i) array += ",0";
    array += "] ";
    expect(array.size() == limits.max_bytes, "dense fixture must fill wire byte budget");
    const auto dense = decode(array, limits, workspace.view());
    expect(dense && dense.value.is_array() && dense.value.size() == 4095 &&
           dense.value.at(4094).integer() == 0,
           "maximum-density array must decode in fixed arena");

    // Insert a pretty opening that selects yyjson's alternate allocation path.
    array[1] = ' ';
    array[2] = ' ';
    array[3] = '0';
    const auto pretty = decode(array, limits, workspace.view());
    expect(pretty && pretty.value.size() == 4094 && pretty.value.at(4093).integer() == 0,
           "dense pretty array must decode in fixed arena");

    std::string partial(64, '[');
    for (std::size_t i = 0; i < 4064; ++i) partial += "0,";
    expect(partial.size() == limits.max_bytes, "open prefix fixture must fill wire byte budget");
    expect(decode(partial, {limits.max_bytes, 64}, workspace.view()).error == Error::syntax,
           "dense maximum-depth malformed prefix must reach syntax rejection");

    std::string object = "{\"ext\":[0";
    for (std::size_t i = 1; i < 4091; ++i) object += ",0";
    object += "]}";
    object.resize(limits.max_bytes, ' ');
    const auto extension = parse(object);
    expect(extension && extension.value.get("ext").size() == 4091,
           "deep extension data must fit the fixed arena");
    expect(static_cast<bool>(comparison(extension.value, limits.max_bytes, workspace.view(),
                                        bytes.data(), bytes.size())),
           "dense decoded extensions must preserve complete comparison encoding");

    // Retain parent keys while encoding nested objects, and include both a
    // key-heavy subtree and a nearly dense array in a maximum-size message.
    std::string fields;
    for (int i = 0; i < 250; ++i) {
        if (i) fields += ',';
        fields += "\"k" + std::to_string(i) + "\":0";
    }
    const std::string suffix = "],\"keys\":{" + fields + "},\"zero\":{}}}}";
    std::string mixed = R"({"n":{"v":{"arr":[0)";
    while (mixed.size() + suffix.size() + 2 <= limits.max_bytes) mixed += ",0";
    mixed += suffix;
    mixed.resize(limits.max_bytes, ' ');
    const auto parsed = parse(mixed);
    const auto nested = parsed.value.get("n").get("v");
    expect(parsed && nested.get("keys").size() == 250 && nested.get("zero").is_object(),
           "maximum-size mixed tree must decode");
    const auto internal = comparison(parsed.value, limits.max_bytes, workspace.view(), bytes.data(), bytes.size());
    expect(static_cast<bool>(internal), "maximum-size mixed tree must encode with arena scratch");
    const std::string internal_bytes(internal.bytes);
    std::array<yyjson_val*, limits.max_bytes / 5 + 1> external_keys{};
    auto external = workspace.view();
    external.keys = external_keys.data();
    external.key_count = external_keys.size();
    const auto from_external = comparison(parsed.value, limits.max_bytes, external, bytes.data(), bytes.size());
    expect(from_external && internal_bytes == from_external.bytes,
           "complete key ordering must match separate scratch without corrupting the tree");
    expect(nested.get("keys").get("k249").integer() == 0,
           "value views must survive use of the arena's scratch");
    std::string duplicate = R"({"m":{"keys":{)" + fields + R"(,"\u006b249":1}}})";
    duplicate.resize(limits.max_bytes, ' ');
    expect(parse(duplicate).error == Error::duplicate_key,
           "maximum-size malformed object must detect an escaped duplicate in nested keys");
}

void shared_arena_upper_bytes_are_preserved() {
    constexpr Limits usb_limits{4096, 8};
    constexpr std::size_t usb_pool = parse_pool_size(usb_limits.max_bytes);
    alignas(std::max_align_t) std::array<std::byte, parse_pool_size(limits.max_bytes)> pool{};
    std::array<char, usb_limits.max_bytes + 4> input{};
    WorkspaceView usb{input.data(), input.size(), pool.data(), pool.size(), nullptr, 0};
    std::fill(pool.begin() + usb_pool, pool.end(), std::byte{0xA5});

    std::string dense = R"({"a":[0)";
    while (dense.size() + 4 <= usb_limits.max_bytes) dense += ",0";
    dense += "]}";
    dense.resize(usb_limits.max_bytes, ' ');
    const auto decoded = decode_object(dense, usb_limits, usb);
    expect(decoded && decoded.value.get("a").size() > 2000, "USB-size dense tree must parse");
    expect(static_cast<bool>(comparison(decoded.value, usb_limits.max_bytes, usb,
                                        bytes.data(), bytes.size())),
           "comparison must work against arena limited by earlier USB decode");
    expect(std::all_of(pool.begin() + usb_pool, pool.end(),
                      [](std::byte value) { return value == std::byte{0xA5}; }),
           "USB decode and comparison must not write into the upper shared arena");
    expect(decode(R"({})", usb_limits, usb).error == Error::none &&
           static_cast<bool>(comparison(decode("[]", usb_limits, usb).value, usb_limits.max_bytes, usb,
                                        bytes.data(), bytes.size())),
           "empty object and array need no key scratch");
}

void number_cases() {
    const auto parsed = parse(R"({"max":9007199254740991.0,"fraction":9007199254740990.5,
      "cancelled":123000.00e-3,"scaled":0.00100e3,"zero":-0.0e-99999999999999999999999,
      "negative":-1,"bool":true,"over":9007199254740992})");
    std::uint64_t number = 42;
    expect(parsed.value.get("max").integer(0, safe_integer, number) && number == safe_integer,
           "exact decimal maximum must decode");
    expect(parsed.value.get("cancelled").integer(1, 123, number) && number == 123,
           "trailing coefficient zeros must cancel across the decimal point");
    expect(parsed.value.get("scaled").integer(1, 1, number) && number == 1,
           "leading fractional zeros must contribute to scale");
    expect(parsed.value.get("zero").integer(0, 0, number) && number == 0,
           "huge negative exponent on negative zero must normalize");
    for (const auto key : {"fraction", "negative", "bool", "over"}) {
        expect(!parsed.value.get(key).integer(0, safe_integer, number),
               "nonintegral, nonnumeric or out-of-bounds token must fail");
    }
}

void comparison_cases() {
    const auto first = compare(R"({"ext":{"☀":[false,null,1],"a":"\u0000","n":1e999999}})");
    expect(first == compare(R"({"ext":{"n":10e999998,"\u0061":"\u0000","☀":[false,null,10e-1]}})"),
           "comparison must ignore key order, equivalent escapes and exact equivalent numbers");
    expect(first != compare(R"({"ext":{"☀":[null,false,1],"a":"\u0000","n":1e999999}})"),
           "comparison must preserve array order");
    expect(first != compare(R"({"ext":{"☀":[false,null,"1"],"a":"\u0000","n":1e999999}})"),
           "comparison must preserve value types");
    expect(first != compare(R"({"ext":{"☀":[false,null,1],"a":"\u0000","n":1e999998}})"),
           "comparison must distinguish arbitrary exponents");

    const std::string huge(4093, '9');
    expect(compare("{\"n\":10e" + huge + "}") ==
           compare("{\"n\":1e1" + std::string(4093, '0') + "}"),
           "exponent carry must preserve thousands of digits");
    expect(compare("{\"n\":0.1e1" + std::string(4093, '0') + "}") ==
           compare("{\"n\":1e" + huge + "}"),
           "exponent borrow must preserve thousands of digits");

    auto value = parse(R"({"a":[0,0,0],"b":1})").value;
    const auto encoded = comparison(value, limits.max_bytes, workspace.view(), bytes.data(),
                                    bytes.size());
    expect(static_cast<bool>(encoded), "literal comparison must encode");
    expect(static_cast<bool>(comparison(value, limits.max_bytes, workspace.view(), bytes.data(),
                                        encoded.bytes.size())), "exact comparison capacity must work");
    expect(comparison(value, limits.max_bytes, workspace.view(), bytes.data(),
                      encoded.bytes.size() - 1).error == Error::resource,
           "comparison overflow must fail without returning partial output");
}

void canonical_cases() {
    using C = CanonicalValue;
    const C items[] = {C::boolean(false), C::unsigned_integer(0), {}};
    const CanonicalMember nested[] = {{"k", C::integer(-9223372036854775807LL - 1)}};
    const CanonicalMember fields[] = {
        {"z", C::string(std::string_view("\"\\\b\t\n\f\r\0\x1f/🪜", 14))},
        {"a", C::array(items, 3)},
        {"nested", C::object(nested, 1)}
    };
    std::array<const CanonicalMember*, 4> keys;
    const auto node = C::object(fields, 3);
    const auto encoded = canonical(node, bytes.data(), bytes.size(), keys.data(), keys.size());
    const std::string_view expected =
        R"({"a":[false,0,null],"nested":{"k":-9223372036854775808},"z":"\"\\\b\t\n\f\r\u0000\u001f/🪜"})";
    expect(encoded && encoded.bytes == expected, "canonical bytes must match control escapes and key order");
    expect(static_cast<bool>(canonical(node, bytes.data(), expected.size(), keys.data(), keys.size())),
           "canonical output must fit exactly");
    expect(canonical(node, bytes.data(), expected.size() - 1, keys.data(), keys.size()).error ==
           Error::resource, "canonical overflow must fail");
    expect(canonical(node, bytes.data(), bytes.size(), keys.data(), 3).error == Error::resource,
           "canonical key scratch must cover the active object path");

    const CanonicalMember duplicate[] = {{"a", {}}, {"a", {}}};
    const CanonicalMember non_ascii[] = {{"é", {}}};
    expect(canonical(C::object(duplicate, 2), bytes.data(), bytes.size(), keys.data(), keys.size())
               .error == Error::duplicate_key, "canonical encoder must reject duplicate keys");
    expect(canonical(C::object(non_ascii, 1), bytes.data(), bytes.size(), keys.data(), keys.size())
               .error == Error::shape, "canonical encoder must reject non-ASCII keys");
    expect(canonical(C::string("\x80"), bytes.data(), bytes.size(), keys.data(), keys.size())
               .error == Error::utf8, "canonical encoder must reject malformed UTF-8");
}

}  // namespace

int main() {
    decoder_cases();
    dense_arena_cases();
    shared_arena_upper_bytes_are_preserved();
    number_cases();
    comparison_cases();
    canonical_cases();
    return failed != 0;
}
