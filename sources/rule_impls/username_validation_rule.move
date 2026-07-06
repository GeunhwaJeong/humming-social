// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Username validation rule for namespaces. Combines Lens V3's
/// `UsernameLengthNamespaceRule` and `UsernameSimpleCharsetNamespaceRule`:
/// enforces a length range and the charset `a-z 0-9 _ -` with no
/// leading `_` or `-`.
module humming::username_validation_rule;

use humming::namespace::{Self, CreateUsernameOp, CreateUsernameTicket};
use humming::rules::{Self, Request, RuleSet, RuleSetCap};

const EUsernameTooShort: u64 = 0;
const EUsernameTooLong: u64 = 1;
const EInvalidCharacter: u64 = 2;
const ECannotStartWithSpecial: u64 = 3;
const EKeyMismatch: u64 = 4;

const CHAR_LOWER_A: u8 = 97;
const CHAR_LOWER_Z: u8 = 122;
const CHAR_ZERO: u8 = 48;
const CHAR_NINE: u8 = 57;
const CHAR_UNDERSCORE: u8 = 95;
const CHAR_HYPHEN: u8 = 45;

public struct UsernameValidationRule has drop {}

public struct Config has store {
    min_length: u64,
    max_length: u64,
}

public fun add(
    set: &mut RuleSet<CreateUsernameOp>,
    cap: &RuleSetCap,
    min_length: u64,
    max_length: u64,
    required: bool,
) {
    rules::add(UsernameValidationRule {}, set, cap, Config { min_length, max_length }, required)
}

public fun remove(set: &mut RuleSet<CreateUsernameOp>, cap: &RuleSetCap) {
    let Config {
        min_length: _,
        max_length: _,
    } = rules::remove<CreateUsernameOp, UsernameValidationRule, Config>(set, cap);
}

/// Validate the username carried by the ticket and stamp its paired
/// request. The key check binds the stamp to exactly this ticket, so a
/// validation of one name can never authorize minting another.
public fun prove(
    set: &RuleSet<CreateUsernameOp>,
    ticket: &CreateUsernameTicket,
    req: &mut Request<CreateUsernameOp>,
) {
    assert!(namespace::ticket_key(ticket) == rules::request_key(req), EKeyMismatch);
    let config = rules::config<CreateUsernameOp, UsernameValidationRule, Config>(set);
    let name = namespace::ticket_name(ticket);
    let bytes = name.as_bytes();
    let len = bytes.length();
    assert!(len >= config.min_length, EUsernameTooShort);
    assert!(len <= config.max_length, EUsernameTooLong);
    let mut i = 0;
    while (i < len) {
        let c = bytes[i];
        let is_valid =
            (c >= CHAR_LOWER_A && c <= CHAR_LOWER_Z) ||
            (c >= CHAR_ZERO && c <= CHAR_NINE) ||
            c == CHAR_UNDERSCORE ||
            c == CHAR_HYPHEN;
        assert!(is_valid, EInvalidCharacter);
        i = i + 1;
    };
    assert!(bytes[0] != CHAR_UNDERSCORE && bytes[0] != CHAR_HYPHEN, ECannotStartWithSpecial);
    rules::add_approval(UsernameValidationRule {}, set, req);
}
