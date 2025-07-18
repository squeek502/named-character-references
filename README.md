# DAFSA for Named Character References

This is an attempt at a purpose-built [DAFSA](https://en.wikipedia.org/wiki/Deterministic_acyclic_finite_state_automaton) of [named character references](https://html.spec.whatwg.org/multipage/named-characters.html#named-character-references) for implementing [the *Named character reference state*](https://html.spec.whatwg.org/multipage/parsing.html#named-character-reference-state) of HTML tokenization. 

That is, the goal is to encode the necessary data compactly while still allowing for fast matching of named character references, while taking full advantage of the note that:

> This list [of named character references] is static and [will not be expanded or changed in the future](https://github.com/whatwg/html/blob/main/FAQ.md#html-should-add-more-named-character-references).

> [!NOTE]
> The implementation in this repository has also been ported to C++ and used in the [Ladybird browser](https://ladybird.org/) ([initial PR](https://github.com/LadybirdBrowser/ladybird/pull/3011), [follow-up PR](https://github.com/LadybirdBrowser/ladybird/pull/5393))

I've written an in-depth article about the DAFSA approach being used, plus a comparison to the approaches used by Chrome/Firefox/Safari here:

- [Slightly better named character reference tokenization than Chrome, Safari, and Firefox](https://www.ryanliptak.com/blog/better-named-character-reference-tokenization/)

The current implementation is an evolution of what's described in that article.

## A description of the modifications made to the DAFSA

I'll skip over describing a typical DAFSA (see [the article for a thorough explanation](https://www.ryanliptak.com/blog/better-named-character-reference-tokenization/)) and only talk about the modifications that were made. The TL;DR is that lookup tables were added to make the search for the first and second character `O(1)` instead of `O(n)`.

- The 'first layer' of nodes in the DAFSA have been extracted out and replaced with a lookup table. This allows for an `O(1)` search for the first character instead of an `O(n)` search. To continue to allow minimal perfect hashing, the `number` field in the lookup table entries contain the total of what the normal number field would be of all of the sibling nodes before it. That is, if we have `a`, `b`, and `c` (in that order) where the count of all possible valid words from each node is 3, 2, and 1 (respectively), then in the lookup table the element corresponding to `a` would have the `number` 0, `b` would get the number 3, and `c` would get the number 5 (since the nodes before it have the numbers 3 and 2, so 3 + 2 = 5). This allows the `O(1)` lookup to emulate the "linear scan over children while incrementally adding up `number` fields" approach to minimal perfect hashing using a DAFSA without the need for the linear scan. In other words, the linear scan is emulated at construction time and the result is stored in the lookup entry corresponding to the node that would get that result.
- A lookup table of bit masks is stored as a way to go from the 'first layer' of nodes to the 'second layer' of nodes. This allows the use of a lookup table for the second layer of nodes while keeping the 'second layer' lookup table small, because:
  - The second layer can only contain a-z and A-Z (inclusive)
  - The validity of any given character can be determined by a bitwise AND
  - The index into the second layer can be determined with a few more bitwise operations and a `@popCount`. This allows for storing the minimum number of elements in the second layer lookup table, since gaps between set bits are disregarded by `@popCount`. For example, if a mask looks like `0b1010`, then we can store a lookup table with 2 elements and our `@popCount` incantation will only ever be able to return either a 0 or a 1 for the index to use.
- The 'second layer' of nodes in the DAFSA have been extracted out, similar to the 'first layer' (but note that the second layer lookup table stores more information).
- The second layer lookup table is a contiguous array, and the starting offset corresponding to each first character is stored in the 'first to second layer' lookup table along with the bit mask to use. The index corresponding to the second character as described above (the `@popCount` stuff) is added to the offset to get the final index of the second layer node.
- After the second layer, the rest of the data is stored using a mostly-normal DAFSA, but there are still a few differences:
  - The `number` field is cumulative, in the same way that the first/second layer store a cumulative `number` field. This cuts down slightly on the amount of work done during the search of a list of children, and we can get away with it because the cumulative `number` fields of the remaining nodes in the DAFSA (after the first and second layer nodes were extracted out) happens to require few enough bits that we can store the cumulative version while staying under our 32-bit budget.
  - Instead of storing a 'last sibling' flag to denote the end of a list of children, the length of each node's list of children is stored. Again, this is mostly done just because there are enough bits available to do so while keeping the DAFSA node within 32 bits.
  - Note: Storing the length of each list of children opens up the possibility of using a binary search instead of a linear search over the children, but due to the consistently small lengths of the lists of children in the remaining DAFSA, a linear search actually seems to be the better option.

Overall, these changes give the DAFSA implementation about a 2x speedup in the 'raw matching speed' benchmark I'm using.

## Data size

- The 'first layer' contains an array of 52 elements, each 2 bytes large, so that's 104 bytes
- The 'first to second layer' linkage is an array of 52 elements, each 8 bytes large, so that's 416 bytes
- The 'second layer' contains a bitpacked array of 630 elements, each 24 bits (3 bytes) large, so that's 1,890 bytes.
- The remaining DAFSA uses nodes that are 4 bytes large, and there are 3,190 nodes, so that's 12,760 bytes.
- All together, the DAFSA uses 104 + 416 + 1,890 + 12,760 = 15,170 bytes
- Minimal perfect hashing is used to allow storing a separate array containing the codepoint(s) to transform each named character reference into
  + This is encoded as packed array of `u21` integers, which allows the storage of 2,231 `character reference -> codepoint(s)` transformations in 5,857 bytes

This means that the full named character reference data is stored in 15,170 + 5,857 = 21,027 bytes or 20.53 KiB. This is actually 318 fewer bytes than the traditional DAFSA implementation would use (3,872 4-byte nodes in a single array).

> [!NOTE]
> It's also possible to remove the semicolon nodes from the DAFSA (inspired by a change that [Safari made](https://github.com/WebKit/WebKit/commit/3483dcf98d883183eb0621479ed8f19451533722)). This would save 796 bytes (199 4-byte nodes removed from the DAFSA), but has a performance cost so I didn't feel it was worth it overall. If you're curious, see [this commit](https://github.com/squeek502/named-character-references/commit/66b10fcbc84f51edf03bc167debd77afbeb31d8c) for how that change could be implemented.

## Development

The DAFSA data is generated and the result is combined with the rest of the relevant code and the combination is then checked into the repository (see `named_character_references.zig`). This is done for two reasons (but I'm not claiming they are good reasons):

1. Zig's `comptime` is [currently too slow](https://github.com/ziglang/zig/issues/4055) to handle generating the DAFSA data at compile-time
2. The generation step rarely needs to change, so it being a manual process is not a big deal

### `generate.zig`

> Note: Running this is only necessary if the encoding of the DAFSA is changed

Requires `entities.json` which can be downloaded from [here](https://html.spec.whatwg.org/entities.json).

```
zig run generate.zig > generated.zig
```

Outputs the generated Zig code to stdout, containing all the generated arrays.

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
- [Applications of finite automata representing large vocabularies](https://doi.org/10.1002/spe.4380230103) (Cláudio L. Lucchesi, Tomasz Kowaltowski, 1993) ([pdf](https://www.ic.unicamp.br/~reltech/1992/92-01.pdf))
- https://pkg.go.dev/github.com/smartystreets/mafsa

Constructing and minimizing the trie when generating the DAFSA:
- http://stevehanov.ca/blog/?id=115
