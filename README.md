# DAFSA for Named Character References

> Disclaimer: This is mostly just me learning about this stuff, don't expect this to be any good (yet?)

This is an attempt at a purpose-built [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) of [named character references](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) for implementing [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization.

That is, the goal is to encode the necessary data compactly while still allowing for fast matching of named character references.

- Each node in the DAFSA is 32 bits, including the numbering needed for minimal perfect hashing
  + This allows the DAFSA to be stored in 3,872 * 4 = 15,488 bytes
- Minimal perfect hashing is used to allow storing a separate array containing the the codepoint(s) to transform each named character reference into
  + This is encoded as packed array of u21 integers, which allows the storage of 2,231 `character reference -> codepoint(s)` transformations in 5,857 bytes

### `named_character_references.zig`

Contains the generated `dafsa` array, the packed version of the `codepoints_lookup` array, and helper functions to deal with both in ways that are relevant to the *Named character reference state* specification.

### `generate.zig`

> Note: Running this is only necessary if the encoding of the `dafsa` or `codepoints_lookup` arrays are changed

Requires `entities.json` which can be downloaded from [here](https://html.spec.whatwg.org/entities.json).

```
zig run generate.zig
```

Outputs the generated Zig code to stdout, containg the `dafsa` array and the `codepoints_lookup` array (unpacked).

### `test.zig`

> Note: This is not a full test of the *Named character reference state* tokenization step; instead, it's a somewhat crude approximation in order to run the `namedEntities.test` test cases

Requires `namedEntities.test` from `html5lib-tests` which can be downloaded from [here](https://github.com/html5lib/html5lib-tests/blob/master/tokenizer/namedEntities.test)

```
zig test test.zig
```

## References / Resources used

Encoding the DAFSA nodes:
- https://web.archive.org/web/20220722224703/http://pages.pathcom.com/~vadco/dawg.html

Minimal perfect hashing:
- https://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.56.5272
- https://pkg.go.dev/github.com/smartystreets/mafsa

Constructing and minimizing the trie when generating the DAFSA:
- http://stevehanov.ca/blog/?id=115
