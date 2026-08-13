import Foundation
import EventKit
import Testing
@testable import RemClaw

struct AgendaCalendarRecoveryStateTests {
    @Test func permissionErrorsPromptCalendarConnection() {
        #expect(AgendaCalendarRecoveryState.from(error: CalendarError.permissionDenied) == .permissionNeeded)
        #expect(AgendaCalendarRecoveryState.from(error: CalendarError.setupFailed) == .permissionNeeded)
    }

    @Test func unrelatedCalendarErrorsDoNotOverrideEmptyAgenda() {
        #expect(AgendaCalendarRecoveryState.from(error: CalendarError.unknown) == nil)
        #expect(AgendaCalendarRecoveryState.from(error: CalendarError.eventNotFound) == nil)
        #expect(AgendaCalendarRecoveryState.from(error: CalendarError.noCalendarAccount) == nil)
    }

    @Test func recoveryCopyDistinguishesLocalPermissionFromProviderConnection() {
        let state = AgendaCalendarRecoveryState.permissionNeeded
        #expect(state.title == "Calendar access needed")
        #expect(state.message.contains("local Calendar access"))
        #expect(!state.message.contains("Connect Calendar"))
        #expect(state.actionTitle == "Review Calendar Settings")
    }

    @Test func calendarAuthorizationPolicySeparatesAgendaReadsFromWrites() {
        #expect(RemCalendarService.CalendarAuthorizationPolicy.allowsRead(.fullAccess))
        #expect(RemCalendarService.CalendarAuthorizationPolicy.allowsWrite(.fullAccess))

        #expect(!RemCalendarService.CalendarAuthorizationPolicy.allowsRead(.writeOnly))
        #expect(RemCalendarService.CalendarAuthorizationPolicy.allowsWrite(.writeOnly))

        #expect(!RemCalendarService.CalendarAuthorizationPolicy.allowsRead(.denied))
        #expect(!RemCalendarService.CalendarAuthorizationPolicy.allowsWrite(.denied))
    }

    @Test func staleCalendarOnlyMirrorsAreHiddenWhenDeviceEventIsUnavailable() {
        let mirror = TaskEvent(
            title: "Mother's Day",
            startDate: Date(timeIntervalSince1970: 1_765_324_800),
            isEvent: true,
            calendarEventID: "holiday-mothers-day",
            isCalendarOnlyMirror: true
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: mirror,
                currentCalendarEventIDs: []
            ) == false
        )
    }

    @Test func legacyCalendarEventsAreHiddenWhileCalendarAccessNeedsRecovery() {
        let legacyEvent = TaskEvent(
            title: "Mother's Day",
            startDate: Date(timeIntervalSince1970: 1_765_324_800),
            isEvent: true,
            calendarEventID: "holiday-mothers-day"
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: legacyEvent,
                currentCalendarEventIDs: [],
                calendarRecoveryState: .permissionNeeded
            ) == false
        )
    }

    @Test func calendarBackedEventsAreHiddenWhileCalendarAccessNeedsRecovery() {
        let calendarBackedEvent = TaskEvent(
            title: "Planning block",
            startDate: Date(timeIntervalSince1970: 1_765_324_800),
            isEvent: true,
            calendarEventID: "rem-created-calendar-event",
            isCalendarOnlyMirror: false
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: calendarBackedEvent,
                currentCalendarEventIDs: ["rem-created-calendar-event"],
                calendarRecoveryState: .permissionNeeded
            ) == false
        )
    }

    @Test func currentCalendarOnlyMirrorsRemainVisible() {
        let mirror = TaskEvent(
            title: "Mother's Day",
            startDate: Date(timeIntervalSince1970: 1_765_324_800),
            isEvent: true,
            calendarEventID: "holiday-mothers-day",
            isCalendarOnlyMirror: true
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: mirror,
                currentCalendarEventIDs: ["holiday-mothers-day"]
            )
        )
    }

    @Test func confirmedCalendarEventsRemainVisibleWhenCalendarAccessIsAvailable() {
        let legacyEvent = TaskEvent(
            title: "Mother's Day",
            startDate: Date(timeIntervalSince1970: 1_765_324_800),
            isEvent: true,
            calendarEventID: "holiday-mothers-day"
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: legacyEvent,
                currentCalendarEventIDs: ["holiday-mothers-day"]
            )
        )
    }

    @Test func regularTasksRemainVisibleWithoutCalendarAccess() {
        let task = TaskEvent(
            title: "Plan relaunch",
            startDate: Date(timeIntervalSince1970: 1_765_324_800)
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: task,
                currentCalendarEventIDs: []
            )
        )
    }

    @Test func regularTasksRemainVisibleWhileCalendarAccessNeedsRecovery() {
        let task = TaskEvent(
            title: "Plan relaunch",
            startDate: Date(timeIntervalSince1970: 1_765_324_800)
        )

        #expect(
            AgendaCalendarMirrorVisibility.shouldShow(
                task: task,
                currentCalendarEventIDs: [],
                calendarRecoveryState: .permissionNeeded
            )
        )
    }
}
