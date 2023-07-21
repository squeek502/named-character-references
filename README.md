# DAFSA for Named Character References

> Disclaimer: This is mostly just me learning about this stuff, don't expect this to be any good (yet?)

This is an attempt at a purpose-built [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) of [named character references](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) for implementing [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization. 

That is, the goal is to encode the necessary data compactly while still allowing for fast matching of named character references, while taking full advantage of the note that:

> This list [of named character references] is static and [will not be expanded or changed in the future](https://github.com/whatwg/html/blob/main/FAQ.md#html-should-add-more-named-character-references).

- Each node in the DAFSA is 32 bits, including the numbering needed for minimal perfect hashing
  + This allows the DAFSA to be stored in 3,872 * 4 = 15,488 bytes
- Minimal perfect hashing is used to allow storing a separate array containing the codepoint(s) to transform each named character reference into
  + This is encoded as packed array of `u21` integers, which allows the storage of 2,231 `character reference -> codepoint(s)` transformations in 5,857 bytes
- This means that the full named character reference data is stored in 15,488 + 5,857 = 21,345 bytes or 20.84 KiB

Some relevant information about the set of named character references:

- There are 61 characters in the full alphabet used by the list of named character references (not including `&` which every named character reference starts with). The characters are (using Zig switch case syntax): `'1'...'8', ';', 'a'...'z', 'A'...'Z'`
- There are 3,872 edges in the minimized trie, so when encoding as a DAFSA any node can be indexed within the limits of a `u12`
- Each node contains "an integer which gives the number of words that would be accepted by the automaton starting from that state" (used for minimal perfect hashing, see the references below). Because the root node's number is irrelevant (it would always just be the total number of named character references), the largest number value in the generated list ends up being 168 which means that all such numbers can fit into a `u8`.
- Most named character references get transformed into 1 codepoint. The maximum value of the first codepoint in the list is `U+1D56B`, meaning all first codepoint values can fit into a `u17`.
- A few named character references get transformed into 2 codepoints. The set of possible second codepoints is limited to 8 different values (`U+0338`, `U+20D2`, `U+200A`, `U+0333`, `U+20E5`, `U+FE00`, `U+006A`, `U+0331`), meaning the value of the second codepoint can be encoded as a `u3` (with a supporting lookup function to go from an enum -> codepoint). One more bit is needed to encode the 'no second codepoint' option.

### `named_character_references.zig`

Contains the generated `dafsa` array, the packed version of the `codepoints_lookup` array, and helper functions to deal with both in ways that are relevant to the *Named character reference state* specification.

### `generate.zig`

> Note: Running this is only necessary if the encoding of the `dafsa` or `codepoints_lookup` arrays are changed

Requires `entities.json` which can be downloaded from [here](https://html.spec.whatwg.org/entities.json).

```
zig run generate.zig
```

Outputs the generated Zig code to stdout, containing the `dafsa` array and the `codepoints_lookup` array (unpacked).

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
