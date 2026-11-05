import DiallerCore
import XCTest

/// SPEC §6 item 17: what a name spoken to Siri resolves to.
final class SiriContactMatcherTests: XCTestCase {
    private func contact(_ id: String, _ name: String, _ number: String, favourite: Bool = false, deleted: Bool = false) -> DirectoryContact {
        DirectoryContact(id: id, displayName: name, uri: "sip:\(number)@dialler", mode: "local", version: 1,
                         deleted: deleted ? true : nil, favourite: favourite ? true : nil)
    }

    private lazy var book = [
        contact("a", "Amara Nwosu", "1120", favourite: true),
        contact("b", "Ben Hartley", "2150"),
        contact("d", "Daniel Okafor", "2310", favourite: true),
        contact("f", "Facilities", "3200"),
        contact("i", "IT Helpdesk", "3000"),
        contact("m", "Marta Lindqvist", "1420"),
        contact("r", "Reception", "1000"),
        contact("s", "Sales Line", "2990"),
        contact("x", "Daniel Osei", "2320"),
        contact("z", "Zoë Dubois", "1500"),
        contact("gone", "Daniel Gone", "9999", deleted: true),
    ]

    func testWholeNameWins() {
        XCTAssertEqual(SiriContactMatcher.match("Reception", in: book), .one(book[6]))
        XCTAssertEqual(SiriContactMatcher.match("it helpdesk", in: book), .one(book[4]), "case insensitive; the whole name beats 'it' starting nothing else")
        XCTAssertEqual(SiriContactMatcher.match("Zoe Dubois", in: book), .one(book[9]), "accents folded")
    }

    func testAnyWordOfTheNameIsEnough() {
        XCTAssertEqual(SiriContactMatcher.match("Amara", in: book), .one(book[0]))
        XCTAssertEqual(SiriContactMatcher.match("Okafor", in: book), .one(book[2]))
        XCTAssertEqual(SiriContactMatcher.match("sales", in: book), .one(book[7]))
        XCTAssertEqual(SiriContactMatcher.match("Hartley Ben", in: book), .one(book[1]), "word order does not matter")
        XCTAssertEqual(SiriContactMatcher.match("Dan", in: book), .several([book[2], book[8]]), "a prefix of a word counts")
    }

    func testSeveralAreOfferedFavouritesFirstAndDeletedNever() {
        XCTAssertEqual(SiriContactMatcher.match("Daniel", in: book), .several([book[2], book[8]]), "the favourite Okafor before Osei; the deleted Daniel is not offered")
    }

    func testNothingAndNumbers() {
        XCTAssertEqual(SiriContactMatcher.match("Priya", in: book), .none)
        XCTAssertEqual(SiriContactMatcher.match("", in: book), .none)
        XCTAssertEqual(SiriContactMatcher.match("2310", in: book), .number("2310"), "digits are dialled, not looked up")
        XCTAssertEqual(SiriContactMatcher.match("+44 7700 900123", in: book), .number("+447700900123"), "a number said with pauses is one number")
    }
}
