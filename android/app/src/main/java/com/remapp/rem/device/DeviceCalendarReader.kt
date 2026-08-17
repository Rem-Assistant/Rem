package com.remapp.rem.device

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.remapp.rem.data.DeviceCalendarEvent
import java.util.Calendar
import java.util.TimeZone

object DeviceCalendarReader {
    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    fun loadTodayEvents(context: Context): List<DeviceCalendarEvent> =
        loadEventsForDay(context, startOfDayMillis())

    fun loadEventsForDay(context: Context, dayStartMillis: Long): List<DeviceCalendarEvent> {
        if (!hasPermission(context)) return emptyList()

        val start = dayStartMillis
        val end = dayStartMillis + 24L * 60L * 60L * 1000L

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
        )
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath(start.toString())
            .appendPath(end.toString())
            .build()

        val out = mutableListOf<DeviceCalendarEvent>()
        context.contentResolver.query(
            uri,
            projection,
            null,
            null,
            "${CalendarContract.Instances.BEGIN} ASC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.EVENT_ID)
            val titleIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.TITLE)
            val beginIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.BEGIN)
            val endIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.END)
            val allDayIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.ALL_DAY)
            val calIdx = cursor.getColumnIndexOrThrow(CalendarContract.Instances.CALENDAR_DISPLAY_NAME)
            while (cursor.moveToNext()) {
                out += DeviceCalendarEvent(
                    id = cursor.getLong(idIdx),
                    title = cursor.getString(titleIdx) ?: "(No title)",
                    startMillis = cursor.getLong(beginIdx),
                    endMillis = cursor.getLong(endIdx),
                    allDay = cursor.getInt(allDayIdx) == 1,
                    calendarName = cursor.getString(calIdx),
                )
            }
        }
        return out
    }

    fun startOfDayMillis(now: Long = System.currentTimeMillis()): Long {
        val zone = TimeZone.getDefault()
        return Calendar.getInstance(zone).apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }

    fun shiftDayStartMillis(dayStartMillis: Long, days: Int): Long {
        val zone = TimeZone.getDefault()
        return Calendar.getInstance(zone).apply {
            timeInMillis = dayStartMillis
            add(Calendar.DAY_OF_MONTH, days)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
    }
}
