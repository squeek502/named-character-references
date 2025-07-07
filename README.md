# DAFSA for Named Character References

This is an attempt at a purpose-built [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) of [named character references](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) for implementing [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization. 

That is, the goal is to encode the necessary data compactly while still allowing for fast matching of named character references, while taking full advantage of the note that:

> This list [of named character references] is static and [will not be expanded or changed in the future](https://github.com/whatwg/html/blob/main/FAQ.md#html-should-add-more-named-character-references).

I've written an in-depth article about the approach I'm using, plus a comparison to the approaches used by Chrome/Firefox/Safari here:

- [Slightly better named character reference tokenization than Chrome, Safari, and Firefox](https://www.ryanliptak.com/blog/better-named-character-reference-tokenization/)

The current implementation in this repository is an evolution of what's described in that article. See the description at the top of [named_character_references.zig](https://github.com/squeek502/named-character-references/blob/master/named_character_references.zig) for the current details.

## Data size

- The 'first layer' contains an array of 52 elements, each 2 bytes large, so that's 104 bytes
- The 'first to second layer' linkage is an array of 52 elements, each 8 bytes large, so that's 416 bytes
- The 'second layer' contains an array of 52 elements, each 16 bytes large on 64-bit architecture, so that's 832 bytes.
  + Each of the 52 elements contain two pointers: one to an array of 1-byte elements, and one to an array of 2-byte elements. Both arrays within a given element are the same lengths, but the lengths vary from element-to-element. All together, the arrays take up 1890 bytes.
- The remaining DAFSA uses nodes that are 32-bits (4-bytes) wide, and there are 3,190 nodes, so that's 12,760 bytes.
- All together, the DAFSA uses 104 + 416 + 832 + 1,890 + 12,760 = 16,002 bytes
- Minimal perfect hashing is used to allow storing a separate array containing the codepoint(s) to transform each named character reference into
  + This is encoded as packed array of `u21` integers, which allows the storage of 2,231 `character reference -> codepoint(s)` transformations in 5,857 bytes
- This means that the full named character reference data is stored in 16,002 + 5,857 = 21,859 bytes or 21.35 KiB

### `named_character_references.zig`

Contains the generated `dafsa` array, the packed version of the `codepoints_lookup` array, and helper functions to deal with both in ways that are relevant to the *Named character reference state* specification.

### `generate.zig`

> Note: Running this is only necessary if the encoding of the `dafsa` or `codepoints_lookup` arrays are changed

Requires `entities.json` which can be downloaded from [here](https://html.spec.whatwg.org/entities.json).

```
zig run generate.zig > generated.zig
```

Outputs the generated Zig code to stdout, containing the `dafsa` array and the `codepoints_lookup` packed array.

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
