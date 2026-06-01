//
//  KulumeterTests.swift
//  KulumeterTests
//
//  Created by Rasmus Sten on 31.5.2026.
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
