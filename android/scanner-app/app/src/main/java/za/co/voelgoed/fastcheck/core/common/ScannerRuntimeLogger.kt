package za.co.voelgoed.fastcheck.core.common

import android.util.Log

/**
 * Lightweight logging wrapper that stays safe in local JVM tests where android.util.Log
 * calls can throw "Method ... not mocked" runtime errors.
 */
object ScannerRuntimeLogger {
    fun d(tag: String, message: String) {
        runCatching { Log.d(tag, message) }.getOrElse { println("D/$tag: $message") }
    }

    fun i(tag: String, message: String) {
        runCatching { Log.i(tag, message) }.getOrElse { println("I/$tag: $message") }
    }

    fun w(tag: String, message: String) {
        runCatching { Log.w(tag, message) }.getOrElse { println("W/$tag: $message") }
    }

    fun e(tag: String, message: String, throwable: Throwable? = null) {
        runCatching {
            if (throwable != null) {
                Log.e(tag, message, throwable)
            } else {
                Log.e(tag, message)
            }
        }.getOrElse {
            println("E/$tag: $message")
            throwable?.printStackTrace()
        }
    }
}
