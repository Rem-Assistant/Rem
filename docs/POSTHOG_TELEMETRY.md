# PostHog Telemetry — Metrics, Test Plan & Dashboard Guide

This document describes all telemetry events added to RemClaw, how to verify them, and how to build PostHog dashboards.

---

## Metrics Overview

### Super Properties (Attached to Every Event)

Set once and automatically included with every `capture()` call:

| Property       | Set When   | Example Value                          |
|----------------|------------|----------------------------------------|
| `platform`     | App init   | `"ios"`                                |
| `app_version`  | App init   | `"1.2.0"`                              |
| `build_number` | App init   | `"47"`                                 |
| `device_model` | App init   | `"iPhone17,1"`                         |
| `os_version`   | App init   | `"Version 19.0 (Build 23A344)"`        |
| `user_id`      | After sign-in | `"abc123-def456..."`                |

---

## Event Definitions

### Auth

| Event             | Properties      | Trigger                          |
|-------------------|-----------------|----------------------------------|
| `user_signed_up`  | `auth_provider` | New user completes sign-up       |
| `user_logged_in`  | `auth_provider` | Existing user signs in           |

### Gateway

| Event                               | Properties                                      | Trigger                    |
|-------------------------------------|--------------------------------------------------|----------------------------|
| `device_gateway_node_connected`    | `session_type`, `reconnect_attempt`, `time_to_connect_ms` | Gateway WebSocket connects |
| `device_gateway_node_disconnected`  | `session_type`, `reconnect_attempt`             | Gateway WebSocket drops    |
| `device_gateway_pairing_completed`  | —                                               | Device pairing succeeds    |

### AI Tools

| Event                    | Properties                                      | Trigger                    |
|--------------------------|--------------------------------------------------|----------------------------|
| `ai_agent_tool_invoked`  | `command`, `success`, `duration_ms`, `source`    | AI command succeeds        |
| `ai_agent_tool_error`    | `command`, `success`, `error_message`, `duration_ms`, `source` | AI command fails |

### Tasks & Events

| Event                          | Properties                                      | Trigger                    |
|--------------------------------|--------------------------------------------------|----------------------------|
| `user_task_created`            | `source`, `type`, `has_due_date`, `has_alert`, `has_repeat` | Task created (manual/voice/chat) |
| `user_task_completed`         | `source`, `type`                                 | Swipe-to-complete in Inbox |
| `user_task_deleted`           | `source`                                         | Task deleted               |
| `user_calendar_event_created` | `source`, `type`, `has_due_date`, `has_alert`, `has_repeat` | Calendar event created     |
| `user_calendar_event_updated`  | `source`, `type`                                 | Calendar event edited      |
| `user_calendar_event_deleted` | `source`                                         | Calendar event deleted     |
| `user_reminder_created`       | `source`                                         | Reminder created via AI    |

### Chat

| Event                   | Properties                         | Trigger           |
|-------------------------|------------------------------------|-------------------|
| `user_chat_message_sent`| `session_key`, `message_length`, `is_first_message` | User sends chat message |

### Voice

| Event                            | Properties                         | Trigger                    |
|----------------------------------|------------------------------------|----------------------------|
| `user_voice_session_started`     | —                                  | Voice mode starts          |
| `user_voice_session_ended`      | `duration_ms`                      | Voice mode ends            |
| `user_voice_capture_started`     | `session_key`                      | First voice capture in session |
| `ai_voice_first_response_received` | `session_key`, `delay_ms`, `response_length` | First AI response in voice session |

### Source Attribution

| Source   | Meaning                                      |
|----------|-----------------------------------------------|
| `manual` | User action via UI (TaskEventView, Inbox)     |
| `voice`  | AI tool invoked while voice session active    |
| `chat`   | AI tool invoked via text chat                 |

---

## PostHog UI Setup

### Step 1: Verify Events Are Arriving

1. Go to [us.posthog.com](https://us.posthog.com) and sign in.
2. Navigate to **Data Management > Events** (left sidebar).
3. After running the app and triggering actions, new event definitions should appear: `ai_agent_tool_invoked`, `user_task_created`, `user_calendar_event_created`, etc.
4. Click any event to inspect properties and recent occurrences.

### Step 2: Create the "RemClaw Launch Health" Dashboard

1. Go to **Dashboards** > click **+ New Dashboard**.
2. Name it **"RemClaw Launch Health"**.
3. Add these insights (click **+ New Insight** for each):

**Insight 1: AI Tool Success Rate**

- Type: **Trends**
- Series A: Event `ai_agent_tool_invoked`, filter `success = true`
- Series B: Event `ai_agent_tool_error`
- Display: **Line chart**
- Purpose: Verify AI tools are working.

**Insight 2: AI Tools by Command**

- Type: **Trends**
- Event: `ai_agent_tool_invoked`
- Breakdown by: `command` property
- Display: **Bar chart** or **Table**
- Purpose: See which AI commands are used most.

**Insight 3: Gateway Connection Health**

- Type: **Trends**
- Series A: Event `device_gateway_node_connected`
- Series B: Event `device_gateway_node_disconnected`
- Display: **Line chart**
- Purpose: Monitor connection stability.

**Insight 4: Time to Connect**

- Type: **Trends**
- Event: `device_gateway_node_connected`
- Metric: Average of `time_to_connect_ms`
- Display: **Line chart**
- Purpose: Track connection latency.

### Step 3: Create the "Task & Event Engagement" Dashboard

1. Create a new dashboard named **"Task & Event Engagement"**.

**Insight 5: Tasks & Events Created (Voice vs Manual)**

- Type: **Trends**
- Series A: Event `user_task_created`
- Series B: Event `user_calendar_event_created`
- Breakdown by: `source` property
- Display: **Stacked bar chart**
- Purpose: Compare voice vs manual creation.

**Insight 6: Voice-to-Manual Ratio**

- Type: **Trends** > click **Enable Formula Mode** (fx button)
- Series A: `user_task_created` + `user_calendar_event_created`, filtered by `source = voice`
- Series B: `user_task_created` + `user_calendar_event_created`, filtered by `source = manual`
- Formula: `A / B`
- Display: **Line chart**
- Purpose: Voice capture to manual input ratio over time.

**Insight 7: Task Lifecycle**

- Type: **Trends**
- Series A: `user_task_created`
- Series B: `user_task_completed`
- Series C: `user_task_deleted`
- Display: **Line chart**
- Purpose: Task creation, completion, and deletion trends.

**Insight 8: Reminder Creation**

- Type: **Trends**
- Event: `user_reminder_created`
- Breakdown by: `source`
- Purpose: Reminder usage by source.

**Insight 9: Calendar Event Updates**

- Type: **Trends**
- Event: `user_calendar_event_updated`
- Breakdown by: `source`
- Purpose: How often events are edited.

### Step 4: Create the Onboarding Funnel (Optional)

1. Type: **Funnel**
2. Steps:
   - `user_signed_up` or `user_logged_in`
   - `device_gateway_node_connected`
   - `user_task_created` OR `user_chat_message_sent`
   - `user_voice_session_started`
3. Purpose: Conversion through core flow.

---

## Test Plan

### Prerequisites

- Build and run RemClaw on a device or simulator.
- Ensure gateway is connected (green status indicator).
- Open PostHog Live Events: [us.posthog.com](https://us.posthog.com) > **Activity > Live Events**.

### Test 1: Auth & Gateway Events

| Action              | Expected PostHog Event              | Verify                                                                 |
|---------------------|-------------------------------------|------------------------------------------------------------------------|
| Sign in with Apple  | `user_logged_in`                    | `auth_provider: "apple"` in event properties                           |
| Gateway connects    | `device_gateway_node_connected`     | `session_type: "node"`, `reconnect_attempt: 0`, `time_to_connect_ms` > 0 |
| Send a chat message | `user_chat_message_sent`            | `session_key`, `message_length`, `is_first_message`                    |
| Start voice session | `user_voice_session_started`        | Event appears                                                          |
| End voice session   | `user_voice_session_ended`         | `duration_ms` > 0                                                      |

### Test 2: AI Tool Invocation Tracking

| Action                                                       | Expected PostHog Event                    | Properties to Verify                                                                 |
|--------------------------------------------------------------|-------------------------------------------|--------------------------------------------------------------------------------------|
| Ask AI "What's on my calendar today?" via chat              | `ai_agent_tool_invoked`                   | `command: "calendar.events"`, `success: true`, `duration_ms` > 0, `source: "chat"`   |
| Ask AI "Create a task called Test Task" via chat            | `ai_agent_tool_invoked` AND `user_task_created` | `ai_agent_tool_invoked`: `command: "tasks.create"`, `source: "chat"`. `user_task_created`: `source: "chat"`, `type: "task"` |
| Ask AI "Add an event called Lunch at noon" via voice         | `ai_agent_tool_invoked` AND `user_calendar_event_created` | Both have `source: "voice"`                                                   |
| Ask AI "Remind me to call John" via voice                    | `ai_agent_tool_invoked` AND `user_reminder_created` | Both have `source: "voice"`                                                   |
| Ask AI to delete calendar event with invalid ID             | `ai_agent_tool_error`                     | `command: "calendar.delete"`, `success: false`, `error_message` present             |

### Test 3: Manual Task/Event Creation

| Action                              | Expected PostHog Event              | Properties to Verify                                                       |
|-------------------------------------|-------------------------------------|----------------------------------------------------------------------------|
| Tap "+" > Create a Task "Buy groceries" | `user_task_created`                 | `source: "manual"`, `type: "task"`, `has_due_date`, `has_alert`, `has_repeat` |
| Tap "+" > Create an Event "Meeting"  | `user_calendar_event_created`       | `source: "manual"`, `type: "event"`, `has_due_date`, `has_alert`, `has_repeat` |
| Edit an existing task title          | *(no event)*                        | `user_task_completed` is **not** fired on edit                             |
| Edit an existing event              | `user_calendar_event_updated`       | `source: "manual"`, `type: "event"`                                         |
| Delete a task from detail view      | `user_task_deleted`                 | `source: "manual"`                                                          |
| Delete an event from detail view    | `user_calendar_event_deleted`       | `source: "manual"`                                                          |
| Swipe-to-complete a task in Inbox   | `user_task_completed`               | `source: "manual"`, `type: "task"                                            |

### Test 4: Voice vs. Manual Ratio Verification

1. Create 2 tasks manually via the "+" button.
2. Create 1 task via voice ("Hey, create a task called walk the dog").
3. In PostHog: **Activity > Events**, filter by `user_task_created`.
4. Verify 3 events: 2 with `source: "manual"`, 1 with `source: "voice"`.
5. Ratio insight (Step 3, Insight 6) should show 0.5 (1 voice / 2 manual).

### Test 5: Gateway Enrichment

| Action                         | Expected                                                                 | Verify                    |
|--------------------------------|--------------------------------------------------------------------------|---------------------------|
| Force disconnect (airplane mode, then back) | `device_gateway_node_disconnected` then `device_gateway_node_connected` | `session_type: "node"`, `reconnect_attempt` ≥ 1, `time_to_connect_ms` > 0 |

### Test 6: Debug Console Verification

With DEBUG mode in Xcode, watch the console for `[Telemetry]` lines. Each tracked event should log its name before being sent to PostHog.

---

## Summary

- **19 events** tracked across auth, gateway, AI tools, tasks, events, reminders, chat, and voice.
- **Super properties** (`platform`, `app_version`, `device_model`, `os_version`, `user_id`) on every event.
- **Source attribution** (`manual`, `voice`, `chat`) for tasks, events, and reminders.
- **`user_task_completed`** fires only on swipe-to-complete in Inbox, not on task edit/save.
