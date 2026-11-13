"""Independent Draft 2020-12 and exact decoded comparison oracle for M2 wire data."""

from decimal import Decimal, InvalidOperation
import json
import re

from jsonschema import Draft202012Validator, validators
from jsonschema.exceptions import ValidationError


WIRE_LIMITS = {"in": 4096, "out": 8192}
DEVICE_TYPES = frozenset(("hello", "command", "heartbeat", "box_status"))
ID_PATTERN = "^[A-Za-z0-9_-]+$"
NUMBER = re.compile(r"(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?")


class ArbitraryNumber:
    """Nonzero number whose exponent is beyond Decimal's representable range."""

    def __init__(self, token):
        self.token = token


def exact_decimal(token):
    try:
        return Decimal(token)
    except InvalidOperation:
        match = NUMBER.fullmatch(token)
        _, whole, fraction, _ = match.groups()
        if all(digit == "0" for digit in whole + (fraction or "")):
            return Decimal(0)
        return ArbitraryNumber(token)


def integer(checker, instance):
    if isinstance(instance, Decimal):
        return instance.is_finite() and instance == instance.to_integral_value()
    return Draft202012Validator.TYPE_CHECKER.is_type(instance, "integer")


def ascii_id(validator, pattern, instance, schema):
    if pattern == ID_PATTERN:
        # The protocol also defines IDs as exclusively the listed ASCII
        # characters. Python's '$' by itself accepts a trailing newline.
        if isinstance(instance, str) and re.fullmatch(pattern, instance) is None:
            yield ValidationError("Invalid ASCII identifier")
    else:
        yield from Draft202012Validator.VALIDATORS["pattern"](validator, pattern, instance, schema)


ExactValidator = validators.extend(
    Draft202012Validator,
    {"pattern": ascii_id},
    type_checker=Draft202012Validator.TYPE_CHECKER.redefine("integer", integer),
)


class WireError(ValueError):
    pass


def pairs(pairs_list):
    result = {}
    for key, value in pairs_list:
        if key in result:
            raise WireError("duplicate_key")
        result[key] = value
    return result


def invalid_constant(_token):
    raise WireError("syntax")


def check_depth(raw):
    depth = 0
    quoted = False
    escaped = False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            if depth > 8:
                raise WireError("depth")
        elif byte in (93, 125):
            depth = max(depth - 1, 0)


def check_strings(value):
    if isinstance(value, dict):
        for key, child in value.items():
            check_strings(key)
            check_strings(child)
    elif isinstance(value, list):
        for child in value:
            check_strings(child)
    elif isinstance(value, str):
        if any("\ud800" <= char <= "\udfff" for char in value):
            raise WireError("syntax")
        if len(value) > 128:
            raise WireError("shape")


class Oracle:
    def __init__(self, schema):
        self.schema = schema
        self.defs = schema["$defs"]
        self.validator = ExactValidator(schema)

    def parse(self, raw, direction):
        if len(raw) > WIRE_LIMITS[direction]:
            raise WireError("size")
        check_depth(raw)
        try:
            text = raw.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise WireError("utf8") from exc

        try:
            value = json.loads(text, parse_int=exact_decimal, parse_float=exact_decimal,
                               object_pairs_hook=pairs, parse_constant=invalid_constant)
        except json.JSONDecodeError as exc:
            raise WireError("syntax") from exc
        check_strings(value)
        if not isinstance(value, dict):
            raise WireError("root_type")

        kind = value.get("type")
        if not isinstance(kind, str):
            raise WireError("shape")
        if (kind in DEVICE_TYPES) != (direction == "in"):
            raise WireError("shape")
        if not self.validator.is_valid(value):
            raise WireError("shape")
        return value

    def resolved(self, rule):
        if "$ref" in rule:
            return self.defs[rule["$ref"].removeprefix("#/$defs/")]
        return rule

    def applies(self, rule, value):
        return self.validator.evolve(schema=rule).is_valid(value)

    def parts(self, rules, value):
        """Find the applicable branches that contribute schema-known properties."""
        for rule in rules:
            if not isinstance(rule, dict):
                continue
            rule = self.resolved(rule)
            yield rule
            for group in ("oneOf", "anyOf"):
                yield from self.parts(
                    (branch for branch in rule.get(group, []) if self.applies(branch, value)), value
                )
            for child in rule.get("allOf", []):
                if "if" in child:
                    outcome = "then" if self.applies(child["if"], value) else "else"
                    if outcome in child:
                        yield from self.parts([child[outcome]], value)
                else:
                    yield from self.parts([child], value)

    def normalize(self, value, rules=None):
        if rules is None:
            rules = [self.schema]
        parts = list(self.parts(rules, value))
        if isinstance(value, dict):
            fields = {}
            for part in parts:
                for key, rule in part.get("properties", {}).items():
                    fields.setdefault(key, []).append(rule)
            return {key: self.normalize(value[key], rules) for key, rules in fields.items()
                    if key in value}
        if isinstance(value, list):
            item_rules = [part["items"] for part in parts if "items" in part]
            return [self.normalize(item, item_rules) for item in value]
        if isinstance(value, Decimal):
            return int(value)
        return value


def length_prefix(size):
    encoded = bytearray()
    while size >= 128:
        encoded.append((size & 127) | 128)
        size >>= 7
    encoded.append(size)
    return bytes(encoded)


def tagged_length(tag, body):
    return tag + length_prefix(len(body)) + body


def signed_digits(value):
    return bytes([int(value < 0)]) + tagged_length(b"", str(abs(value)).encode("ascii"))


def number_parts(value):
    if isinstance(value, Decimal):
        sign, digits, exponent = value.as_tuple()
        coefficient = "".join(map(str, digits))
    else:
        sign, whole, fraction, exponent = NUMBER.fullmatch(value.token).groups()
        fraction = fraction or ""
        coefficient = whole + fraction
        exponent = int(exponent or 0) - len(fraction)
        sign = int(bool(sign))
    coefficient = coefficient.lstrip("0")
    if not coefficient:
        return 0, b"0", 0
    significant = coefficient.rstrip("0")
    return sign, significant.encode("ascii"), exponent + len(coefficient) - len(significant)


def comparison(value):
    if value is None:
        return b"n"
    if isinstance(value, bool):
        return b"t" if value else b"f"
    if isinstance(value, str):
        return tagged_length(b"s", value.encode("utf-8"))
    if isinstance(value, list):
        return b"a" + length_prefix(len(value)) + b"".join(map(comparison, value))
    if isinstance(value, dict):
        members = sorted(value.items(), key=lambda pair: pair[0].encode("utf-8"))
        return b"o" + length_prefix(len(members)) + b"".join(
            comparison(key) + comparison(item) for key, item in members
        )
    sign, coefficient, exponent = number_parts(value)
    return tagged_length(b"d" + bytes([sign]), coefficient) + signed_digits(exponent)
