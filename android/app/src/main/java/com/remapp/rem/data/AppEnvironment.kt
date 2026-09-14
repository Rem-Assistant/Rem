package com.remapp.rem.data

import com.remapp.rem.BuildConfig

enum class AppEnvironment(
    val storageKey: String,
    val label: String,
    val baseUrl: String,
) {
    Staging(
        storageKey = "staging",
        label = "Staging",
        baseUrl = BuildConfig.API_BASE_URL_STAGING.trimEnd('/'),
    ),
    Production(
        storageKey = "production",
        label = "Production",
        baseUrl = BuildConfig.API_BASE_URL_PRODUCTION.trimEnd('/'),
    );

    companion object {
        fun fromStorage(value: String?): AppEnvironment =
            entries.firstOrNull { it.storageKey == value } ?: Staging
    }
}
