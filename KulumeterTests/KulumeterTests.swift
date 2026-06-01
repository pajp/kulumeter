//
//  KulumeterTests.swift
//  KulumeterTests
//
import Foundation
import Testing
@testable import Kulumeter

struct KulumeterTests {

    @Test func parsesContestIDFromHiddenInput() async throws {
        let html = #"""
        <form action="/contest/log-save/" method="post">
            <input type="hidden" name="contest_id" value="42">
        </form>
        """#

        #expect(KilometrikisaClient.parseContestID(from: html) == "42")
    }

    @Test func parsesContestIDFromLogListURL() async throws {
        let html = #"""
        fetch("/contest/log_list_json/123/?start=1&end=2")
        """#

        #expect(KilometrikisaClient.parseContestID(from: html) == "123")
    }

    @Test func parsesContestIDFromDataAttribute() async throws {
        let html = #"<div data-contest-id="456"></div>"#

        #expect(KilometrikisaClient.parseContestID(from: html) == "456")
    }

    @Test func parsesContestIDFromJavaScriptVariable() async throws {
        let html = #"const contestId = "789";"#

        #expect(KilometrikisaClient.parseContestID(from: html) == "789")
    }

    @Test func returnsNilWhenContestIDIsMissing() async throws {
        let html = #"<form action="/contest/log-save/" method="post"></form>"#

        #expect(KilometrikisaClient.parseContestID(from: html) == nil)
    }

    @Test func parsesCSRFTokenFromLoginForm() async throws {
        let html = #"""
        <input type='hidden' name='csrfmiddlewaretoken' value='abc123MaskedToken' />
        """#

        #expect(KilometrikisaClient.parseCSRFToken(from: html) == "abc123MaskedToken")
    }

    @Test func parsesTeamPathFromProfileLink() async throws {
        let html = #"""
        <a href="/teams/example-cycling/">Example Cycling</a>
        """#

        #expect(KilometrikisaClient.parseTeamPath(from: html) == "/teams/example-cycling/")
    }

    @Test func ignoresTeamRegistrationPathWhenParsingTeamPath() async throws {
        let html = #"""
        <a href="/teams/register/">Ilmoita joukkue</a>
        <a href="/teams/favorites/">Suosikit</a>
        <a href="/teams/example-cycling/">Example Cycling</a>
        """#

        #expect(KilometrikisaClient.parseTeamPath(from: html) == "/teams/example-cycling/")
    }

    @Test func parsesTeamRankingTable() async throws {
        let html = #"""
        <html>
            <h1>Example Cycling</h1>
            <table>
                <thead>
                    <tr><th>#</th><th>Nimi</th><th>Km yht.</th><th>Km (lihas)</th><th>Km (sähkö)</th><th>Ajopäivät</th></tr>
                </thead>
                <tbody>
                    <tr><td>13</td><td>Rider One</td><td>226,0</td><td>226,0</td><td>0,0</td><td>4</td></tr>
                    <tr class="highlight"><td>14</td><td>Current Rider</td><td>178,4</td><td>178,4</td><td>0,0</td><td>19</td></tr>
                </tbody>
            </table>
        </html>
        """#

        let ranking = try #require(KilometrikisaClient.parseTeamRanking(from: html, path: "/teams/example-cycling/"))
        #expect(ranking.name == "Example Cycling")
        #expect(ranking.rows.count == 2)
        #expect(ranking.rows[1].rank == 14)
        #expect(ranking.rows[1].name == "Current Rider")
        #expect(ranking.rows[1].totalKilometers == "178,4")
        #expect(ranking.rows[1].isCurrentUser)
    }

    @Test func ignoresSiteHeadingWhenParsingTeamRankingName() async throws {
        let html = #"""
        <html>
            <h1>KILOMETRIKISA</h1>
            <h1>Example Cycling</h1>
            <table>
                <thead>
                    <tr><th>#</th><th>Nimi</th><th>Km yht.</th><th>Km (lihas)</th><th>Km (sähkö)</th><th>Ajopäivät</th></tr>
                </thead>
                <tbody>
                    <tr><td>14</td><td>Current Rider</td><td>178,4</td><td>178,4</td><td>0,0</td><td>19</td></tr>
                </tbody>
            </table>
        </html>
        """#

        let ranking = try #require(KilometrikisaClient.parseTeamRanking(from: html, path: "/teams/example-cycling/"))
        #expect(ranking.name == "Example Cycling")
    }

    @Test func parsesCurrentUserHighlightFromTableCellStyle() async throws {
        let html = #"""
        <html>
            <h1>Example Cycling</h1>
            <table>
                <thead>
                    <tr><th>#</th><th>Nimi</th><th>Km yht.</th><th>Km (lihas)</th><th>Km (sähkö)</th><th>Ajopäivät</th></tr>
                </thead>
                <tbody>
                    <tr><td>13</td><td>Rider One</td><td>226,0</td><td>226,0</td><td>0,0</td><td>4</td></tr>
                    <tr><td style="background-color: #ffffcc">14</td><td>Current Rider</td><td>178,4</td><td>178,4</td><td>0,0</td><td>19</td></tr>
                </tbody>
            </table>
        </html>
        """#

        let ranking = try #require(KilometrikisaClient.parseTeamRanking(from: html, path: "/teams/example-cycling/"))
        #expect(!ranking.rows[0].isCurrentUser)
        #expect(ranking.rows[1].isCurrentUser)
    }

    @Test func parsesCurrentUserHighlightFromUsername() async throws {
        let html = #"""
        <html>
            <h1>Example Cycling</h1>
            <table>
                <thead>
                    <tr><th>#</th><th>Nimi</th><th>Km yht.</th><th>Km (lihas)</th><th>Km (sähkö)</th><th>Ajopäivät</th></tr>
                </thead>
                <tbody>
                    <tr><td>13</td><td>Rider One</td><td>226,0</td><td>226,0</td><td>0,0</td><td>4</td></tr>
                    <tr><td>14</td><td>Sample User</td><td>178,4</td><td>178,4</td><td>0,0</td><td>19</td></tr>
                </tbody>
            </table>
        </html>
        """#

        let ranking = try #require(KilometrikisaClient.parseTeamRanking(from: html, path: "/teams/example-cycling/", currentUsername: "sampleuser"))
        #expect(!ranking.rows[0].isCurrentUser)
        #expect(ranking.rows[1].isCurrentUser)
    }

    @Test func formatsTeamNameFromPathWhenPageNameIsGeneric() async throws {
        let html = #"""
        <html>
            <h1>KILOMETRIKISA</h1>
            <table>
                <thead>
                    <tr><th>#</th><th>Nimi</th><th>Km yht.</th><th>Km (lihas)</th><th>Km (sähkö)</th><th>Ajopäivät</th></tr>
                </thead>
                <tbody>
                    <tr><td>14</td><td>Current Rider</td><td>178,4</td><td>178,4</td><td>0,0</td><td>19</td></tr>
                </tbody>
            </table>
        </html>
        """#

        let ranking = try #require(KilometrikisaClient.parseTeamRanking(from: html, path: "/teams/example-cycling/"))
        #expect(ranking.name == "Example-Cycling")
    }

    @Test func parsesLoggedDatesFromJSONFeed() async throws {
        let data = #"""
        [
            {"id": 1, "start": "2026-05-29", "title": "9.92 km"},
            {"id": 2, "km_date": "2026-05-31", "title": "11,11 km"}
        ]
        """#.data(using: .utf8)!

        #expect(KilometrikisaClient.parseLoggedDates(from: data) == ["2026-05-29", "2026-05-31"])
    }

    @Test func ignoresUnloggedDatesFromJSONFeed() async throws {
        let data = #"""
        {
            "start": "2026-06-01",
            "end": "2026-06-02",
            "events": [
                {"id": 1, "start": "2026-06-01", "title": "0 km"},
                {"id": 2, "start": "2026-06-02", "title": ""},
                {"id": 3, "km_date": "2026-06-03", "km_amount": 9.5}
            ]
        }
        """#.data(using: .utf8)!

        #expect(KilometrikisaClient.parseLoggedDates(from: data) == ["2026-06-03"])
    }

    @Test func parsesLoggedDatesFromCalendarInputHTML() async throws {
        let data = #"""
        [
            {
                "start": "2026-05-31",
                "title": "<form class=\"km-log-form\"><input type=\"hidden\" name=\"contest_id\" value=\"55\"><input class=\"km-amount\" name=\"km_amount\" value=\"11,1\"></form>"
            },
            {
                "start": "2026-06-01",
                "title": "<form class=\"km-log-form\"><input class=\"km-amount\" name=\"km_amount\" value=\"0\"></form>"
            }
        ]
        """#.data(using: .utf8)!

        #expect(KilometrikisaClient.parseLoggedDates(from: data) == ["2026-05-31"])
    }

    @Test func parsesLoggedDatesFromNestedCalendarInputHTML() async throws {
        let data = #"""
        [
            {
                "start": "2026-05-29T00:00:00",
                "className": "fc-event-hori fc-event-start fc-event-end",
                "metadata": {
                    "html": "<span class=&quot;ui-spinner&quot;><input class=&quot;ui-spinner-input km-amount&quot; name=&quot;km_amount&quot; value=&quot;9,9&quot;></span>"
                }
            },
            {
                "start": "2026-05-30T00:00:00",
                "metadata": {
                    "html": "<input class=&quot;km-amount&quot; name=&quot;km_amount&quot; value=&quot;0&quot;>"
                }
            }
        ]
        """#.data(using: .utf8)!

        #expect(KilometrikisaClient.parseLoggedDates(from: data) == ["2026-05-29"])
    }

    @Test func parsesLoggedDatesFromPlainFullCalendarTitles() async throws {
        let data = #"""
        [
            {"start": "2026-05-28T00:00:00", "title": "2,4"},
            {"start": "2026-05-29T00:00:00", "title": "9.9"},
            {"start": "2026-05-30T00:00:00", "title": "0"}
        ]
        """#.data(using: .utf8)!

        #expect(KilometrikisaClient.parseLoggedDates(from: data) == ["2026-05-28", "2026-05-29"])
    }

}
