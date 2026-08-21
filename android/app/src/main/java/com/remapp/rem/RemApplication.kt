package com.remapp.rem

import android.app.Application
import com.remapp.rem.data.RemRepository
import com.remapp.rem.data.SessionStore

class RemApplication : Application() {
    lateinit var store: SessionStore
        private set
    lateinit var repository: RemRepository
        private set

    override fun onCreate() {
        super.onCreate()
        store = SessionStore(this)
        repository = RemRepository(store)
    }
}
