package com.remapp.rem.ui

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier as ComposeModifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.remapp.rem.data.BriefItem
import com.remapp.rem.data.DeviceCalendarEvent
import com.remapp.rem.data.RemTask
import com.remapp.rem.data.TaskSuggestion
import com.remapp.rem.device.DeviceCalendarReader
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

@Composable
fun AgendaPane(
    state: RemUiState,
    onNewTaskTitle: (String) -> Unit,
    onCreateTask: () -> Unit,
    onCompleteTask: (RemTask) -> Unit,
    onOpenTask: (RemTask) -> Unit,
    onOpenBriefItem: (String) -> Unit,
    onAcceptSuggestion: (TaskSuggestion) -> Unit,
    onDismissSuggestion: (TaskSuggestion) -> Unit,
    onRequestCalendarPermission: () -> Unit,
    onShiftAgendaDay: (Int) -> Unit,
    onJumpAgendaToday: () -> Unit,
) {
    val dayStart = state.agendaDayStartMillis.takeIf { it > 0L }
        ?: DeviceCalendarReader.startOfDayMillis()
    val isToday = localDateOf(dayStart) == LocalDate.now()
    val brief = state.brief
    val scheduled = state.tasks.filter { !it.isDone && it.fallsOn(dayStart) }
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            AgendaDatePager(
                dayStartMillis = dayStart,
                onPrevious = { onShiftAgendaDay(-1) },
                onNext = { onShiftAgendaDay(1) },
                onJumpToday = onJumpAgendaToday,
            )
        }
        if (isToday && brief != null) {
            item { BriefCard(brief.counts.progress, brief.counts.done, brief.counts.total, brief.summary) }
            if (brief.blocked.isNotEmpty()) {
                item { SectionLabel("Blocked") }
                items(brief.blocked, key = { "b-${it.id}" }) { BriefRow(it, onOpenBriefItem) }
            }
            if (brief.overdue.isNotEmpty()) {
                item { SectionLabel("Overdue") }
                items(brief.overdue, key = { "o-${it.id}" }) { BriefRow(it, onOpenBriefItem) }
            }
        }
        if (isToday && state.suggestions.isNotEmpty()) {
            item { SectionLabel("Suggestions") }
            items(state.suggestions, key = { it.key }) { suggestion ->
                SuggestionRow(suggestion, onAcceptSuggestion, onDismissSuggestion)
            }
        }
        item { SectionLabel("Calendar") }
        if (!state.calendarPermissionGranted) {
            item {
                Column(
                    modifier = ComposeModifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color(0xFF242018))
                        .padding(14.dp),
                ) {
                    Text("Show device calendar events on Agenda.", color = RemMuted, fontSize = 14.sp)
                    Spacer(modifier = ComposeModifier.height(8.dp))
                    Button(
                        onClick = onRequestCalendarPermission,
                        colors = ButtonDefaults.buttonColors(containerColor = RemBlue),
                    ) { Text("Allow calendar access") }
                }
            }
        } else if (state.calendarEvents.isEmpty()) {
            item {
                Text(
                    if (isToday) "No calendar events today." else "No calendar events this day.",
                    color = RemMuted,
                    fontSize = 14.sp,
                )
            }
        } else {
            items(state.calendarEvents, key = { "c-${it.id}-${it.startMillis}" }) { event ->
                CalendarRow(event)
            }
        }
        item { SectionLabel("Tasks") }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = state.newTaskTitle,
                    onValueChange = onNewTaskTitle,
                    modifier = ComposeModifier.weight(1f),
                    placeholder = { Text("Add a task", color = RemMuted) },
                    singleLine = true,
                    shape = RoundedCornerShape(14.dp),
                    colors = agendaFieldColors(),
                )
                TextButton(onClick = onCreateTask, enabled = state.newTaskTitle.isNotBlank() && !state.busy) {
                    Text("Add", color = RemBlue)
                }
            }
        }
        if (scheduled.isEmpty()) {
            item {
                Text(
                    if (isToday) "Nothing scheduled today." else "Nothing scheduled this day.",
                    color = RemMuted,
                    fontSize = 14.sp,
                )
            }
        } else {
            items(scheduled, key = { it.id }) { task ->
                TaskRowClickable(task, onCompleteTask, onOpenTask)
            }
        }
    }
}

@Composable
fun InboxPane(
    state: RemUiState,
    onNewTaskTitle: (String) -> Unit,
    onCreateTask: () -> Unit,
    onCompleteTask: (RemTask) -> Unit,
    onOpenTask: (RemTask) -> Unit,
) {
    val inbox = state.tasks.filter { !it.isScheduled && !it.isDone }
    LazyColumn(
        modifier = ComposeModifier.fillMaxSize().padding(horizontal = 16.dp),
        contentPadding = PaddingValues(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Inbox", color = RemCream, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
                if (inbox.isNotEmpty()) {
                    Spacer(modifier = ComposeModifier.width(10.dp))
                    Text("${inbox.size}", color = RemMuted, fontSize = 18.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = state.newTaskTitle,
                    onValueChange = onNewTaskTitle,
                    modifier = ComposeModifier.weight(1f),
                    placeholder = { Text("Add a task", color = RemMuted) },
                    singleLine = true,
                    shape = RoundedCornerShape(14.dp),
                    colors = agendaFieldColors(),
                )
                TextButton(onClick = onCreateTask, enabled = state.newTaskTitle.isNotBlank() && !state.busy) {
                    Text("Add", color = RemBlue)
                }
            }
        }
        if (inbox.isEmpty()) {
            item {
                Column(modifier = ComposeModifier.fillMaxWidth().padding(top = 36.dp, bottom = 12.dp)) {
                    Text("Inbox is empty", color = RemCream, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(modifier = ComposeModifier.height(6.dp))
                    Text("Tasks you capture will appear here.", color = RemMuted, fontSize = 14.sp)
                }
            }
        } else {
            items(inbox, key = { it.id }) { task ->
                TaskRowClickable(task, onCompleteTask, onOpenTask)
            }
        }
    }
}

@Composable
private fun AgendaDatePager(
    dayStartMillis: Long,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onJumpToday: () -> Unit,
) {
    val isToday = localDateOf(dayStartMillis) == LocalDate.now()
    Row(
        modifier = ComposeModifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onPrevious) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                contentDescription = "Previous day",
                tint = RemMuted,
            )
        }
        Column(
            modifier = ComposeModifier.weight(1f).clickable(enabled = !isToday, onClick = onJumpToday),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                relativeAgendaLabel(dayStartMillis),
                color = RemCream,
                fontSize = 22.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                formattedAgendaDate(dayStartMillis),
                color = RemMuted,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
            if (!isToday) {
                Text("Jump to today", color = RemBlue, fontSize = 12.sp)
            }
        }
        IconButton(onClick = onNext) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = "Next day",
                tint = RemMuted,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskDetailSheet(
    state: RemUiState,
    onTitle: (String) -> Unit,
    onPriority: (String) -> Unit,
    onStatus: (String) -> Unit,
    onSave: () -> Unit,
    onDelete: () -> Unit,
    onClose: () -> Unit,
    onStartFocus: () -> Unit,
) {
    val task = state.selectedTask ?: return
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onClose,
        sheetState = sheetState,
        containerColor = Color(0xFF171512),
        contentColor = RemCream,
    ) {
        Column(modifier = ComposeModifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Task", color = RemCream, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, modifier = ComposeModifier.weight(1f))
                IconButton(onClick = onClose) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = RemMuted)
                }
            }
            Spacer(modifier = ComposeModifier.height(8.dp))
            OutlinedTextField(
                value = state.detailTitle,
                onValueChange = onTitle,
                label = { Text("Title") },
                modifier = ComposeModifier.fillMaxWidth(),
                colors = agendaFieldColors(),
            )
            Spacer(modifier = ComposeModifier.height(12.dp))
            Text("Priority", color = RemMuted, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("low", "medium", "high").forEach { p ->
                    val selected = state.detailPriority == p
                    Button(
                        onClick = { onPriority(p) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (selected) RemBlue else Color(0xFF242018),
                            contentColor = if (selected) Color.White else RemCream,
                        ),
                    ) { Text(p) }
                }
            }
            Spacer(modifier = ComposeModifier.height(12.dp))
            Text("Status", color = RemMuted, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("pending", "in_progress", "completed").forEach { s ->
                    val selected = state.detailStatus == s
                    Button(
                        onClick = { onStatus(s) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (selected) RemBlue else Color(0xFF242018),
                            contentColor = if (selected) Color.White else RemCream,
                        ),
                    ) { Text(s.replace('_', ' ')) }
                }
            }
            if (!task.startDate.isNullOrBlank()) {
                Spacer(modifier = ComposeModifier.height(12.dp))
                Text("Starts ${task.startDate}", color = RemMuted, fontSize = 13.sp)
            }
            if (!task.runStatus.isNullOrBlank()) {
                Text("Run: ${task.runStatus}", color = RemMuted, fontSize = 13.sp)
            }
            if (!task.isDone) {
                Spacer(modifier = ComposeModifier.height(16.dp))
                Button(
                    onClick = onStartFocus,
                    modifier = ComposeModifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color(0xFF34C759),
                        contentColor = Color.Black,
                    ),
                ) { Text("Start a focus session") }
            }
            Spacer(modifier = ComposeModifier.height(20.dp))
            Button(
                onClick = onSave,
                enabled = !state.busy,
                modifier = ComposeModifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = RemBlue),
            ) { Text("Save") }
            Spacer(modifier = ComposeModifier.height(8.dp))
            OutlinedButton(onClick = onDelete, modifier = ComposeModifier.fillMaxWidth()) {
                Text("Delete task", color = Color(0xFFFF8A80))
            }
            Spacer(modifier = ComposeModifier.height(24.dp))
        }
    }
}

@Composable
private fun BriefCard(progress: Float, done: Int, total: Int, summary: String?) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1B2744))
            .padding(16.dp),
    ) {
        Text("Daily brief", color = RemCream, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
        Spacer(modifier = ComposeModifier.height(8.dp))
        LinearProgressIndicator(
            progress = { progress },
            modifier = ComposeModifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(8.dp)),
            color = RemBlue,
            trackColor = Color(0xFF2A3550),
        )
        Spacer(modifier = ComposeModifier.height(8.dp))
        Text("$done of $total done today", color = RemMuted, fontSize = 13.sp)
        if (!summary.isNullOrBlank()) {
            Spacer(modifier = ComposeModifier.height(8.dp))
            Text(summary, color = RemCream, fontSize = 14.sp)
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        color = RemCream,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        modifier = ComposeModifier.padding(top = 8.dp),
    )
}

@Composable
private fun BriefRow(item: BriefItem, onOpen: (String) -> Unit) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF242018))
            .clickable { onOpen(item.id) }
            .padding(14.dp),
    ) {
        Text(item.title, color = RemCream, fontSize = 15.sp)
        val meta = listOfNotNull(item.bucket, item.priority, item.runStatus, item.latestActivitySummary).joinToString(" · ")
        if (meta.isNotBlank()) {
            Text(meta, color = RemMuted, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun SuggestionRow(
    suggestion: TaskSuggestion,
    onAccept: (TaskSuggestion) -> Unit,
    onDismiss: (TaskSuggestion) -> Unit,
) {
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF242018))
            .padding(14.dp),
    ) {
        Text(suggestion.title, color = RemCream, fontSize = 15.sp)
        Text(suggestion.subtitle, color = RemMuted, fontSize = 12.sp)
        Row {
            TextButton(onClick = { onAccept(suggestion) }) { Text("Accept", color = RemBlue) }
            TextButton(onClick = { onDismiss(suggestion) }) { Text("Dismiss", color = RemMuted) }
        }
    }
}

@Composable
private fun CalendarRow(event: DeviceCalendarEvent) {
    val time = if (event.allDay) {
        "All day"
    } else {
        val start = DateFormat.format("h:mm a", Date(event.startMillis))
        val end = DateFormat.format("h:mm a", Date(event.endMillis))
        "$start – $end"
    }
    Column(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF1F1A14))
            .padding(14.dp),
    ) {
        Text(event.title, color = RemCream, fontSize = 15.sp)
        Text(
            listOfNotNull(time, event.calendarName).joinToString(" · "),
            color = RemMuted,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun TaskRowClickable(
    task: RemTask,
    onCompleteTask: (RemTask) -> Unit,
    onOpenTask: (RemTask) -> Unit,
) {
    Row(
        modifier = ComposeModifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF242018))
            .clickable { onOpenTask(task) }
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { onCompleteTask(task) }) {
            Icon(Icons.Default.CheckCircle, contentDescription = "Complete", tint = RemBlue)
        }
        Column(modifier = ComposeModifier.weight(1f)) {
            Text(task.title, color = RemCream, fontSize = 16.sp)
            val meta = listOfNotNull(task.priority, task.startDate?.take(16), task.runStatus).joinToString(" · ")
            if (meta.isNotBlank()) {
                Text(meta, color = RemMuted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun agendaFieldColors() = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
    focusedBorderColor = RemBlue,
    unfocusedBorderColor = RemMuted.copy(alpha = 0.35f),
    focusedTextColor = RemCream,
    unfocusedTextColor = RemCream,
    cursorColor = RemBlue,
    focusedLabelColor = RemMuted,
    unfocusedLabelColor = RemMuted,
)

private fun localDateOf(millis: Long): LocalDate =
    Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).toLocalDate()

private fun relativeAgendaLabel(dayStartMillis: Long): String {
    val date = localDateOf(dayStartMillis)
    val today = LocalDate.now()
    return when (date) {
        today -> "Today"
        today.plusDays(1) -> "Tomorrow"
        today.minusDays(1) -> "Yesterday"
        else -> date.format(DateTimeFormatter.ofPattern("EEEE", Locale.getDefault()))
    }
}

private fun formattedAgendaDate(dayStartMillis: Long): String =
    localDateOf(dayStartMillis).format(DateTimeFormatter.ofPattern("MMM d yyyy", Locale.getDefault()))

private fun RemTask.fallsOn(dayStartMillis: Long): Boolean {
    val taskDay = startDate?.let(::parseTaskDayStartMillis) ?: return false
    return taskDay == dayStartMillis
}

private fun parseTaskDayStartMillis(raw: String): Long? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val zone = ZoneId.systemDefault()
    val instant = when {
        trimmed.length == 10 -> runCatching {
            LocalDate.parse(trimmed).atStartOfDay(zone).toInstant()
        }.getOrNull()
        else -> runCatching { Instant.parse(trimmed) }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(trimmed).toInstant() }.getOrNull()
            ?: runCatching { ZonedDateTime.parse(trimmed).toInstant() }.getOrNull()
            ?: runCatching { LocalDateTime.parse(trimmed).atZone(zone).toInstant() }.getOrNull()
            ?: runCatching { LocalDate.parse(trimmed.take(10)).atStartOfDay(zone).toInstant() }.getOrNull()
    } ?: return null
    return DeviceCalendarReader.startOfDayMillis(instant.toEpochMilli())
}
