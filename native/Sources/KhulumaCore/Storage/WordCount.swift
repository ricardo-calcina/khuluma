/// Words as usage has always counted them: Python's
/// `len(re.findall(r"\b\w+\b", text, re.UNICODE))`, i.e. maximal runs of
/// word characters. Python's `\w` is `str.isalnum()` or `_`: letters
/// (Lu, Ll, Lt, Lm, Lo) and anything with a Unicode numeric type. Combining
/// marks are not word characters (ICU's `\w` differs there, so no regex).
/// Checked against Python 3.15 / Unicode 17 for every code point.
public enum WordCount {
  public static func count(_ text: String) -> Int {
    var words = 0
    var inWord = false
    for scalar in text.unicodeScalars {
      let word = isWordCharacter(scalar)
      if word && !inWord { words += 1 }
      inWord = word
    }
    return words
  }

  public static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "_" { return true }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default:
      return scalar.properties.numericType != nil
    }
  }
}
