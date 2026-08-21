package com.remapp.rem.data

import android.content.Context
import androidx.core.content.edit

/** Local-only model enable/disable prefs (mirrors iOS ModelPreferencesStore). */
class ModelPreferencesStore(context: Context) {
    private val prefs = context.getSharedPreferences("rem_model_prefs", Context.MODE_PRIVATE)

    fun disabledIds(): Set<String> =
        prefs.getStringSet(KEY_DISABLED, emptySet())?.toSet() ?: emptySet()

    fun isEnabled(modelId: String): Boolean = modelId !in disabledIds()

    fun setEnabled(modelId: String, enabled: Boolean) {
        val next = disabledIds().toMutableSet()
        if (enabled) next.remove(modelId) else next.add(modelId)
        prefs.edit { putStringSet(KEY_DISABLED, next) }
    }

    companion object {
        private const val KEY_DISABLED = "rem.models.disabledSelectionIDs"
    }
}
