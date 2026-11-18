#include "json_internal.hpp"

#include <array>
#include <charconv>

namespace vault::json::detail {
namespace {

struct NumberParts {
    bool negative;
    std::string_view whole;
    std::string_view fraction;
    bool exponent_negative;
    std::string_view exponent;
    std::int64_t adjustment;
};

NumberParts split_number(std::string_view token) {
    const bool negative = token.front() == '-';
    if (negative) token.remove_prefix(1);

    const auto exp_pos = token.find_first_of("eE");
    const auto mantissa = token.substr(0, exp_pos);
    auto exponent = exp_pos == token.npos ? std::string_view{"0"} : token.substr(exp_pos + 1);
    const bool exponent_negative = exponent.front() == '-';
    if (exponent_negative || exponent.front() == '+') exponent.remove_prefix(1);
    const auto first_exp_digit = exponent.find_first_not_of('0');
    exponent = first_exp_digit == exponent.npos ? std::string_view{"0"} : exponent.substr(first_exp_digit);

    const auto dot = mantissa.find('.');
    auto whole = mantissa.substr(0, dot);
    auto fraction = dot == mantissa.npos ? std::string_view{} : mantissa.substr(dot + 1);
    const auto original_fraction_length = fraction.size();
    if (whole == "0") {
        whole = {};
        const auto first = fraction.find_first_not_of('0');
        fraction = first == fraction.npos ? std::string_view{} : fraction.substr(first);
    }
    std::size_t trailing = 0;
    if (!fraction.empty()) {
        const auto last = fraction.find_last_not_of('0');
        const auto length = last == fraction.npos ? 0 : last + 1;
        trailing = fraction.size() - length;
        fraction = fraction.substr(0, length);
    }
    if (fraction.empty() && !whole.empty()) {
        const auto length = whole.find_last_not_of('0') + 1;
        trailing += whole.size() - length;
        whole = whole.substr(0, length);
    }
    if (whole.empty() && fraction.empty()) return {false, "0", {}, false, "0", 0};

    // Digits skipped at the start of the fraction do not increase the
    // exponent. The original fractional width accounts for them.
    const auto adjustment = static_cast<std::int64_t>(trailing) -
                            static_cast<std::int64_t>(original_fraction_length);
    return {negative, whole, fraction, exponent_negative && exponent != "0",
            exponent, adjustment};
}

std::uint64_t saturated_exponent(std::string_view exponent, std::uint64_t cap) {
    std::uint64_t value = 0;
    for (const char digit : exponent) {
        const auto next = static_cast<std::uint64_t>(digit - '0');
        if (value > (cap - next) / 10) return cap;
        value = value * 10 + next;
    }
    return value;
}

// Walk from the least significant digit, adding or subtracting a small
// offset without converting or expanding the full exponent.
template<typename Emit>
void adjust_digits(std::string_view digits, std::int64_t offset, Emit emit) {
    std::size_t index = 0;
    for (auto it = digits.rbegin(); it != digits.rend(); ++it) {
        auto digit = (*it - '0') + offset % 10;
        offset /= 10;
        if (digit >= 10) {
            digit -= 10;
            ++offset;
        } else if (digit < 0) {
            digit += 10;
            --offset;
        }
        emit(index++, static_cast<char>('0' + digit));
    }
    while (offset > 0) {
        emit(index++, static_cast<char>('0' + offset % 10));
        offset /= 10;
    }
}

bool comparison_exponent(const NumberParts& parts, Output& output) {
    // The adjustment is bounded by the token width. Exponents fitting in
    // 18 digits can be normalized with wide arithmetic; larger exponents
    // keep their sign and use digit-string arithmetic.
    if (parts.exponent.size() <= 18) {
        const auto magnitude = static_cast<std::int64_t>(
            saturated_exponent(parts.exponent, 999'999'999'999'999'999ULL));
        const auto signed_exponent = parts.exponent_negative ? -magnitude : magnitude;
        const auto adjusted = signed_exponent + parts.adjustment;
        const auto absolute = adjusted < 0 ? -adjusted : adjusted;
        std::array<char, 20> buffer;
        const auto converted = std::to_chars(buffer.data(), buffer.data() + buffer.size(), absolute);
        const auto digits = std::string_view(buffer.data(),
                                            static_cast<std::size_t>(converted.ptr - buffer.data()));
        return output.byte(adjusted < 0 ? 1 : 0) && output.length(digits.size()) &&
               output.append(digits);
    }

    const auto offset = parts.exponent_negative ? -parts.adjustment : parts.adjustment;
    std::size_t length = 0;
    adjust_digits(parts.exponent, offset, [&length](std::size_t index, char digit) {
        if (digit != '0') length = index + 1;
    });
    if (!output.byte(parts.exponent_negative ? 1 : 0) || !output.length(length)) return false;
    auto* digits = output.reserve(length);
    if (!digits) return false;
    adjust_digits(parts.exponent, offset, [digits, length](std::size_t index, char digit) {
        if (index < length) digits[length - 1 - index] = digit;
    });
    return true;
}

}  // namespace

bool integer(std::string_view token, std::uint64_t min, std::uint64_t max, std::uint64_t& result) {
    if (token.empty() || min > max || max > safe_integer) return false;
    const auto parts = split_number(token);
    if (parts.whole == "0" && parts.fraction.empty()) {
        if (min != 0) return false;
        result = 0;
        return true;
    }
    if (parts.negative) return false;

    constexpr std::int64_t safe_digits = 16;
    const auto cap = static_cast<std::uint64_t>(token.size()) + safe_digits;
    const auto magnitude = static_cast<std::int64_t>(saturated_exponent(parts.exponent, cap));
    const auto scale = (parts.exponent_negative ? -magnitude : magnitude) + parts.adjustment;
    const auto length = parts.whole.size() + parts.fraction.size();
    if (scale < 0 || static_cast<std::uint64_t>(scale) + length > safe_digits) return false;

    // Compare each digit against the inclusive upper bound before adding it.
    std::uint64_t value = 0;
    const auto push = [&value, max](std::uint64_t digit) {
        if (digit > max || value > (max - digit) / 10) return false;
        value = value * 10 + digit;
        return true;
    };
    for (const char digit : parts.whole) if (!push(digit - '0')) return false;
    for (const char digit : parts.fraction) if (!push(digit - '0')) return false;
    for (std::int64_t i = 0; i < scale; ++i) if (!push(0)) return false;
    if (value < min) return false;
    result = value;
    return true;
}

bool comparison_number(std::string_view token, Output& output) {
    const auto parts = split_number(token);
    return output.byte('d') && output.byte(parts.negative ? 1 : 0) &&
           output.length(parts.whole.size() + parts.fraction.size()) &&
           output.append(parts.whole) && output.append(parts.fraction) &&
           comparison_exponent(parts, output);
}

}  // namespace vault::json::detail
