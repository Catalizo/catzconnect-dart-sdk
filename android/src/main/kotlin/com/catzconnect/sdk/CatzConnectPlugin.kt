package com.catzconnect.sdk

import android.content.Context
import android.os.Build
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityServiceException
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.model.IntegrityErrorCode
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The `catzconnect/attest` method channel for Catz Connect app keys.
 *
 * - `info` → platform, emulator heuristic, OS version.
 * - `read` / `write` / `remove` → small non-secret values (the install's
 *   device id) in this plugin's own SharedPreferences file.
 * - `requestIntegrityToken {nonce, cloudProjectNumber?}` → a Play Integrity
 *   token from a classic request:
 *   `IntegrityManagerFactory.create(context).requestIntegrityToken(
 *   IntegrityTokenRequest.builder().setNonce(nonce).setCloudProjectNumber(n).build())`.
 *
 * Errors are `result.error(<reason>, message, {errorCode})` where reason is
 * `integrity_<IntegrityErrorCode name in lower case>`, which the Dart side
 * turns into a CatzAttestationException.
 *
 * Nothing runs until the Dart side calls the channel, so apps that only use
 * server keys are not affected by this plugin being registered.
 */
class CatzConnectPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val ch = MethodChannel(binding.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler(this)
        channel = ch
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("unsupported_platform", "The catzconnect plugin is not attached to an engine.", null)
            return
        }
        when (call.method) {
            "info" -> result.success(
                mapOf(
                    "platform" to "android",
                    "emulator" to isProbablyEmulator(),
                    "appAttestSupported" to false,
                    "osVersion" to (Build.VERSION.RELEASE ?: ""),
                    "sdkInt" to Build.VERSION.SDK_INT,
                ),
            )
            "read" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrEmpty()) {
                    result.error("bad_arguments", "Missing key", null)
                } else {
                    result.success(prefs(ctx).getString(key, null))
                }
            }
            "write" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key.isNullOrEmpty() || value == null) {
                    result.error("bad_arguments", "Missing key or value", null)
                } else {
                    prefs(ctx).edit().putString(key, value).apply()
                    result.success(null)
                }
            }
            "remove" -> {
                val key = call.argument<String>("key")
                if (key.isNullOrEmpty()) {
                    result.error("bad_arguments", "Missing key", null)
                } else {
                    prefs(ctx).edit().remove(key).apply()
                    result.success(null)
                }
            }
            "requestIntegrityToken" -> requestIntegrityToken(ctx, call, result)
            "generateKey", "attestKey", "generateAssertion" ->
                result.error("unsupported_platform", "App Attest is available on iOS only.", null)
            else -> result.notImplemented()
        }
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun requestIntegrityToken(ctx: Context, call: MethodCall, result: MethodChannel.Result) {
        val once = OnceResult(result)
        val nonce = call.argument<String>("nonce")
        if (nonce.isNullOrEmpty()) {
            once.error("integrity_nonce_too_short", "Missing nonce", null)
            return
        }
        val projectRaw = call.argument<String>("cloudProjectNumber")?.trim()
        val projectNumber: Long? =
            if (projectRaw.isNullOrEmpty()) {
                null
            } else {
                projectRaw.toLongOrNull() ?: run {
                    once.error(
                        "integrity_cloud_project_number_is_invalid",
                        "The Google Cloud project number must be digits only (got \"$projectRaw\").",
                        null,
                    )
                    return
                }
            }
        try {
            val builder = IntegrityTokenRequest.builder().setNonce(nonce)
            if (projectNumber != null) builder.setCloudProjectNumber(projectNumber)
            IntegrityManagerFactory.create(ctx.applicationContext)
                .requestIntegrityToken(builder.build())
                .addOnSuccessListener { response ->
                    val token = response.token()
                    if (token.isNullOrEmpty()) {
                        once.error("integrity_empty_token", "Play Integrity returned no token.", null)
                    } else {
                        once.success(token)
                    }
                }
                .addOnFailureListener { e -> once.fail(e) }
                .addOnCanceledListener {
                    once.error("integrity_cancelled", "The Play Integrity request was cancelled.", null)
                }
        } catch (e: Exception) {
            once.fail(e)
        }
    }

    /** Answers a method call exactly once, whatever the Task listeners do. */
    private class OnceResult(private val result: MethodChannel.Result) {
        private val done = AtomicBoolean(false)

        fun success(value: Any?) {
            if (done.compareAndSet(false, true)) result.success(value)
        }

        fun error(code: String, message: String?, details: Any?) {
            if (done.compareAndSet(false, true)) result.error(code, message, details)
        }

        fun fail(e: Exception) {
            if (e is IntegrityServiceException) {
                val code = e.errorCode
                error(
                    "integrity_" + integrityErrorName(code),
                    "Play Integrity error $code (${integrityErrorName(code)}): ${e.message ?: ""}",
                    mapOf("errorCode" to code),
                )
            } else {
                error("integrity_error", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    companion object {
        const val CHANNEL = "catzconnect/attest"
        private const val PREFS = "com.catzconnect.sdk.attest"

        /** IntegrityErrorCode (classic requests) → lower-case name. */
        fun integrityErrorName(code: Int): String =
            when (code) {
                IntegrityErrorCode.API_NOT_AVAILABLE -> "api_not_available"
                IntegrityErrorCode.APP_NOT_INSTALLED -> "app_not_installed"
                IntegrityErrorCode.APP_UID_MISMATCH -> "app_uid_mismatch"
                IntegrityErrorCode.CANNOT_BIND_TO_SERVICE -> "cannot_bind_to_service"
                IntegrityErrorCode.CLIENT_TRANSIENT_ERROR -> "client_transient_error"
                IntegrityErrorCode.CLOUD_PROJECT_NUMBER_IS_INVALID -> "cloud_project_number_is_invalid"
                IntegrityErrorCode.GOOGLE_SERVER_UNAVAILABLE -> "google_server_unavailable"
                IntegrityErrorCode.INTERNAL_ERROR -> "internal_error"
                IntegrityErrorCode.NETWORK_ERROR -> "network_error"
                IntegrityErrorCode.NO_ERROR -> "no_error"
                IntegrityErrorCode.NONCE_IS_NOT_BASE64 -> "nonce_is_not_base64"
                IntegrityErrorCode.NONCE_TOO_LONG -> "nonce_too_long"
                IntegrityErrorCode.NONCE_TOO_SHORT -> "nonce_too_short"
                IntegrityErrorCode.PLAY_SERVICES_NOT_FOUND -> "play_services_not_found"
                IntegrityErrorCode.PLAY_SERVICES_VERSION_OUTDATED -> "play_services_version_outdated"
                IntegrityErrorCode.PLAY_STORE_ACCOUNT_NOT_FOUND -> "play_store_account_not_found"
                IntegrityErrorCode.PLAY_STORE_NOT_FOUND -> "play_store_not_found"
                IntegrityErrorCode.PLAY_STORE_VERSION_OUTDATED -> "play_store_version_outdated"
                IntegrityErrorCode.TOO_MANY_REQUESTS -> "too_many_requests"
                else -> "code_$code"
            }

        /**
         * A heuristic, only used by the Dart side to explain a failed
         * attestation ("use a debug token on emulators"); it never blocks
         * anything.
         */
        fun isProbablyEmulator(): Boolean {
            val fingerprint = Build.FINGERPRINT ?: ""
            val model = Build.MODEL ?: ""
            val hardware = Build.HARDWARE ?: ""
            val product = Build.PRODUCT ?: ""
            return fingerprint.startsWith("generic") ||
                fingerprint.contains("emulator") ||
                fingerprint.contains("sdk_gphone") ||
                model.contains("google_sdk") ||
                model.contains("Emulator") ||
                model.contains("Android SDK built for") ||
                (Build.MANUFACTURER ?: "").contains("Genymotion") ||
                hardware == "goldfish" ||
                hardware == "ranchu" ||
                product.startsWith("sdk_") ||
                product == "google_sdk" ||
                (Build.BRAND.orEmpty().startsWith("generic") && Build.DEVICE.orEmpty().startsWith("generic"))
        }
    }
}
