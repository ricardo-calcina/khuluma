import Testing
@testable import KhulumaCore

/// Brands → engine boost terms (the KHULUMA_BOOST_VOCABULARY experiment).
struct BoostTermsTests {
  private func sheet(brands: [(heard: String, write: String)] = [],
                     words: [(heard: String, write: String)] = [],
                     fillers: [String] = []) -> VocabularySheet {
    VocabularySheet(
      fillers: fillers,
      brands: brands.map { .init(heard: $0.heard, write: $0.write) },
      words: words.map { .init(heard: $0.heard, write: $0.write) })
  }

  @Test func distinctWritesComeOutInOrder() {
    let terms = BoostTerms.from(sheet(brands: [
      ("kahlua", "Khuluma"), ("parakeet", "Parakeet"), ("scribe", "ElevenLabs"),
    ]))
    #expect(terms == [
      BoostTerm(text: "Khuluma", aliases: ["kahlua"]),
      // "parakeet" is the write itself, differently cased: not an alias.
      BoostTerm(text: "Parakeet"),
      BoostTerm(text: "ElevenLabs", aliases: ["scribe"]),
    ])
  }

  @Test func theSameWriteMergesCaseInsensitivelyFirstSpellingWins() {
    let terms = BoostTerms.from(sheet(brands: [
      ("kahlua", "Khuluma"), ("caluma", "khuluma"), ("KHULUMA", "Khuluma"),
    ]))
    #expect(terms == [BoostTerm(text: "Khuluma", aliases: ["kahlua", "caluma"])])
  }

  @Test func aliasesSkipTheWriteItselfAndDuplicates() {
    let terms = BoostTerms.from(sheet(brands: [
      ("Khuluma", "Khuluma"), ("kahlua", "Khuluma"), ("KAHLUA", "Khuluma"), ("caluma", "Khuluma"),
    ]))
    #expect(terms == [BoostTerm(text: "Khuluma", aliases: ["kahlua", "caluma"])])
  }

  @Test func shortAndPathLikeWritesAreSkipped() {
    let terms = BoostTerms.from(sheet(brands: [
      ("vee", "VR"), ("site", "example.com/x"), ("mail", "a@b.com"), ("path", #"C:\dir"#),
      ("under", "my_project"), ("ok", "OKD"), ("fine", "Parakeet"),
    ]))
    #expect(terms == [BoostTerm(text: "OKD", aliases: ["ok"]),
                      BoostTerm(text: "Parakeet", aliases: ["fine"])])
  }

  @Test func wordsAndFillersAreNeverUsed() {
    let terms = BoostTerms.from(sheet(
      brands: [("kahlua", "Khuluma")],
      words: [("gonna", "going to")],
      fillers: ["um", "erm"]))
    #expect(terms == [BoostTerm(text: "Khuluma", aliases: ["kahlua"])])
  }

  @Test func anEmptySheetBoostsNothing() {
    #expect(BoostTerms.from(.empty) == [])
  }
}
