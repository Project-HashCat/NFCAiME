package com.lar55.nfcaime

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import android.nfc.tech.NfcF
import android.nfc.tech.TagTechnology
import android.os.Bundle
import android.util.Base64
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.random.Random


class MainActivity : ComponentActivity(), NfcAdapter.ReaderCallback {
    companion object {
        private const val MODE_LOCAL = "local"
        private const val MODE_REMOTE = "remote"
        private const val PUBLIC_REPOSITORY_URL = "https://github.com/Project-HashCat/NFCAiME"
    }

    private val nfcAdapter by lazy { NfcAdapter.getDefaultAdapter(this) }
    private val isProcessing = AtomicBoolean(false)
    @Volatile
    private var serverMode = MODE_LOCAL
    @Volatile
    private var cardServerUrl = ""
    @Volatile
    private var serverPublicKey = ""
    private val preferences by lazy { getSharedPreferences("settings", MODE_PRIVATE) }
    private var latestCard: SavedAimeCard? = null
    private var lastSnapshot: ScanSnapshot? = null
    private var currentSection by mutableStateOf(AppSection.Scan)
    private var privacyDisplay by mutableStateOf(false)
    private var scanMode by mutableStateOf(ScanMode.Local)
    private var scanSnapshot by mutableStateOf<ScanSnapshot?>(null)
    private var fallbackResult by mutableStateOf<Pair<String, String>?>(null)
    private var savedCards by mutableStateOf<List<SavedAimeCard>>(emptyList())
    private var remoteServers by mutableStateOf<List<RemoteServer>>(emptyList())
    private var selectedRemoteServerUrl by mutableStateOf("")
    private var serverDraftName by mutableStateOf("")
    private var serverDraftUrl by mutableStateOf("")
    private var serverDraftPublicKey by mutableStateOf("")
    private var serverStatus by mutableStateOf("")
    private var uploadLogStatus by mutableStateOf("")
    private var canSaveLatestCard by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        privacyDisplay = preferences.getBoolean("privacy_display", false)
        serverMode = preferences.getString("server_mode", MODE_LOCAL) ?: MODE_LOCAL
        scanMode = if (serverMode == MODE_REMOTE) ScanMode.Remote else ScanMode.Local
        refreshSavedCards()
        refreshRemoteServers()
        setContent {
            NFCAimeApp(
                state = NFCAimeUiState(
                    section = currentSection,
                    scanMode = scanMode,
                    privacyDisplay = privacyDisplay,
                    snapshot = scanSnapshot,
                    fallbackResult = fallbackResult,
                    savedCards = savedCards,
                    remoteServers = remoteServers,
                    selectedRemoteServerUrl = selectedRemoteServerUrl,
                    serverDraftName = serverDraftName,
                    serverDraftUrl = serverDraftUrl,
                    serverDraftPublicKey = serverDraftPublicKey,
                    serverStatus = serverStatus,
                    uploadLogStatus = uploadLogStatus,
                    canSaveLatestCard = canSaveLatestCard,
                    appVersion = BuildConfig.VERSION_NAME,
                    versionCode = BuildConfig.VERSION_CODE,
                ),
                actions = NFCAimeUiActions(
                    onSectionChange = { currentSection = it },
                    onScanModeChange = ::applyScanMode,
                    onPrivacyDisplayChange = ::updatePrivacyDisplay,
                    onServerSelected = ::selectRemoteServer,
                    onServerNameChange = { serverDraftName = it },
                    onServerUrlChange = { serverDraftUrl = it },
                    onServerPublicKeyChange = { serverDraftPublicKey = it },
                    onSaveServer = ::saveServerDraft,
                    onSaveLatestCard = ::saveLatestCard,
                    onClearCards = ::clearSavedCards,
                    onOpenReleases = ::openReleases,
                    onUploadLogs = ::uploadDebugLogs,
                    onStartRead = {
                        Toast.makeText(this, R.string.scan_hint, Toast.LENGTH_SHORT).show()
                    },
                ),
            )
        }

        if (nfcAdapter == null) {
            showResult(getString(R.string.read_failed), getString(R.string.nfc_unavailable))
            return
        }

        restoreLastScan()
    }

    private fun updatePrivacyDisplay(enabled: Boolean) {
        privacyDisplay = enabled
        preferences.edit().putBoolean("privacy_display", enabled).apply()
        renderLastSnapshot()
        refreshSavedCards()
    }

    private fun applyScanMode(mode: ScanMode) {
        scanMode = mode
        serverMode = if (mode == ScanMode.Remote) MODE_REMOTE else MODE_LOCAL
        preferences.edit().putString("server_mode", serverMode).apply()
        if (mode == ScanMode.Remote) {
            refreshRemoteServers()
        } else {
            cardServerUrl = ""
            serverPublicKey = ""
            serverStatus = getString(R.string.local_binding_warning)
        }
    }

    private fun refreshRemoteServers() {
        val servers = loadRemoteServers()
        remoteServers = servers
        val selectedUrl = preferences.getString("selected_remote_server_url", null)
        val selected = servers.firstOrNull { it.url == selectedUrl } ?: servers.firstOrNull()
        applySelectedServer(selected)
    }

    private fun applySelectedServer(server: RemoteServer?) {
        selectedRemoteServerUrl = server?.url.orEmpty()
        serverDraftName = server?.name.orEmpty()
        serverDraftUrl = server?.url.orEmpty()
        serverDraftPublicKey = server?.publicKey.orEmpty()
        cardServerUrl = server?.url.orEmpty()
        serverPublicKey = server?.publicKey.orEmpty()
        serverStatus = if (server == null) {
            getString(R.string.no_remote_server)
        } else {
            getString(R.string.server_saved_local_only)
        }
    }

    private fun selectRemoteServer(url: String) {
        val server = remoteServers.firstOrNull { it.url == url } ?: return
        preferences.edit().putString("selected_remote_server_url", server.url).apply()
        applySelectedServer(server)
    }

    private fun saveServerDraft() {
        val normalizedUrl = try {
            serverDraftUrl.toPostEndpoint()
        } catch (exc: IOException) {
            serverStatus = exc.message ?: exc.javaClass.simpleName
            return
        }
        val publicKey = serverDraftPublicKey.trim()
        try {
            Spad0Rsa.validate(publicKey)
        } catch (exc: Exception) {
            serverStatus = exc.message ?: exc.javaClass.simpleName
            return
        }
        val name = serverDraftName.trim().ifEmpty { getString(R.string.default_server_name) }
        val updated = loadRemoteServers().toMutableList()
        val server = RemoteServer(name = name, url = normalizedUrl, publicKey = publicKey)
        val index = updated.indexOfFirst { it.url == normalizedUrl }
        if (index >= 0) {
            updated[index] = server
        } else {
            updated.add(server)
        }
        saveRemoteServers(updated)
        preferences.edit().putString("selected_remote_server_url", normalizedUrl).apply()
        refreshRemoteServers()
        Toast.makeText(this, R.string.server_saved, Toast.LENGTH_SHORT).show()
    }

    private fun saveLatestCard() {
        latestCard?.let {
            upsertSavedCard(it)
            Toast.makeText(this, R.string.card_saved, Toast.LENGTH_SHORT).show()
            refreshSavedCards()
            canSaveLatestCard = false
        }
    }

    private fun clearSavedCards() {
        preferences.edit().remove("saved_cards").apply()
        refreshSavedCards()
    }

    private fun openReleases() {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PUBLIC_REPOSITORY_URL)))
    }

    override fun onResume() {
        super.onResume()
        nfcAdapter?.enableReaderMode(
            this,
            this,
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_F or
                NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK,
            null,
        )
    }

    override fun onPause() {
        nfcAdapter?.disableReaderMode(this)
        super.onPause()
    }

    override fun onTagDiscovered(tag: Tag?) {
        if (tag == null || !isProcessing.compareAndSet(false, true)) return

        try {
            val nfcF = NfcF.get(tag)
            val mifare = MifareClassic.get(tag)
            when {
                nfcF != null -> nfcF.use(::handleFelica)
                mifare != null -> mifare.use(::handleMifare)
                else -> throw IOException("不支持的 NFC 卡片类型")
            }
        } catch (exc: Exception) {
            appendDebugLog("read failed: ${exc.message ?: exc.javaClass.simpleName}")
            showResult(
                getString(R.string.read_failed),
                exc.message ?: exc.javaClass.simpleName,
            )
        } finally {
            isProcessing.set(false)
        }
    }

    private fun handleFelica(card: NfcF) {
        val idm = card.tag.id
        val rc = Random.Default.nextBytes(16)
        card.writeWithoutEncryption(0x80 to rc).requireFelicaWriteSuccess()

        val spad0 = runCatching {
            card.readWithoutEncryption(0)
                .extractFelicaBlocks(expectedBlockCount = 1)
                .copyOfRange(0, 16)
        }.getOrNull()
        val securityBlockNumbers = intArrayOf(0x82, 0x86, 0x90, 0x91)
        val blocks = try {
            card.readWithoutEncryption(
                securityBlockNumbers[0],
                *securityBlockNumbers.copyOfRange(1, securityBlockNumbers.size),
            )
                .extractFelicaBlocks(expectedBlockCount = 4)
        } catch (exc: IOException) {
            securityBlockNumbers.fold(ByteArray(0)) { data, blockNumber ->
                data + card.readWithoutEncryption(blockNumber)
                    .extractFelicaBlocks(expectedBlockCount = 1)
            }
        }

        val idBlock = blocks.copyOfRange(0, 16)
        val ckv = blocks.copyOfRange(16, 32)
        val wcnt = blocks.copyOfRange(32, 48)
        val maca = blocks.copyOfRange(48, 56)
        val dfc = idBlock.copyOfRange(8, 10)

        val idmText = idm.toDisplayHex(":")
        val ckvText = ckv.toDisplayHex()
        val wcntText = wcnt.toDisplayHex()
        val macaText = maca.toDisplayHex()
        latestCard = null

        showSnapshot(
            ScanSnapshot(
                title = getString(R.string.felica),
                code = null,
                idm = idmText,
                ckv = ckvText,
                wcnt = wcntText,
                maca = macaText,
                accessCode = if (serverMode == MODE_REMOTE) "查询中" else "-",
                error = null,
            ),
            persist = false,
        )

        if (serverMode == MODE_LOCAL) {
            showSnapshot(
                ScanSnapshot(
                    title = getString(R.string.felica),
                    code = null,
                    idm = idmText,
                    ckv = ckvText,
                    wcnt = wcntText,
                    maca = macaText,
                    accessCode = "-",
                    error = null,
                ),
            )
            return
        }

        val endpoint = cardServerUrl.trim()
        if (endpoint.isEmpty()) {
            showSnapshot(
                ScanSnapshot(
                    title = getString(R.string.felica),
                    code = null,
                    idm = idmText,
                    ckv = ckvText,
                    wcnt = wcntText,
                    maca = macaText,
                    accessCode = "-",
                    error = getString(R.string.no_remote_server),
                ),
            )
            return
        }
        val encryptedSpad0 = try {
            Spad0Rsa.encrypt(spad0 ?: throw IOException("缺少可上传的卡片安全数据"), serverPublicKey)
        } catch (exc: Exception) {
            showSnapshot(
                ScanSnapshot(
                    title = getString(R.string.felica),
                    code = null,
                    idm = idmText,
                    ckv = ckvText,
                    wcnt = wcntText,
                    maca = macaText,
                    accessCode = "-",
                    error = exc.message ?: exc.javaClass.simpleName,
                ),
            )
            return
        }

        val payload = JSONObject().apply {
            put("idm", idm.toHex())
            put("rc", rc.toHex())
            put("idBlock", idBlock.toHex())
            put("ckv", ckv.toHex())
            put("wcnt", wcnt.toHex())
            put("maca", maca.toHex())
            put("companyCode", "01")
            put("firmwareVersion", "02")
            put("dfc", dfc.toHex())
            put("spad0Encrypted", encryptedSpad0)
        }
        val account = try {
            postCardPayload(payload)
        } catch (exc: Exception) {
            val error = exc.message ?: exc.javaClass.simpleName
            appendDebugLog("felica submit failed: $error")
            showSnapshot(
                ScanSnapshot(
                    title = getString(R.string.felica),
                    code = null,
                    idm = idmText,
                    ckv = ckvText,
                    wcnt = wcntText,
                    maca = macaText,
                    accessCode = "-",
                    error = error,
                ),
            )
            return
        }
        val code = account.optString("code").takeIf { it.isNotBlank() }
        val error = account.opt("error")?.toString()
        val accessCode = account.optNonBlankString("accessCodeHex")?.uppercase() ?: "-"
        val spad0AccessCode = account.optNonBlankString("spad0AccessCodeHex")?.uppercase()
        val spad0DecodeError = account.optNonBlankString("spad0DecodeError")
        val accessCodeMatchesSpad0 = account.optNullableBoolean("accessCodeMatchesSpad0")
        val konamiCardNumber = account.optNonBlankString("konamiCardNumber")?.uppercase()
        val privateNetworkNumber = account.optNonBlankString("privateNetworkNumber")?.uppercase()
        if (!account.optBoolean("ok", true)) {
            val message = error ?: "未知错误"
            appendDebugLog("felica server returned error: $message")
            showSnapshot(
                ScanSnapshot(
                    title = getString(R.string.felica),
                    code = code,
                    idm = idmText,
                    ckv = ckvText,
                    wcnt = wcntText,
                    maca = macaText,
                    accessCode = accessCode,
                    spad0AccessCode = spad0AccessCode,
                    konamiCardNumber = konamiCardNumber,
                    privateNetworkNumber = privateNetworkNumber,
                    spad0DecodeError = spad0DecodeError,
                    accessCodeMatchesSpad0 = accessCodeMatchesSpad0,
                    error = message,
                ),
            )
            return
        }
        latestCard = accessCode.takeIf { it != "-" }?.let {
            SavedAimeCard(
                label = "AiMe 卡",
                code = code,
                idm = idmText,
                accessCode = it,
                konamiCardNumber = konamiCardNumber,
                privateNetworkNumber = privateNetworkNumber,
                cardType = getString(R.string.felica),
                updatedAt = System.currentTimeMillis(),
            )
        }

        showSnapshot(
            ScanSnapshot(
                title = getString(R.string.felica),
                code = code,
                idm = idmText,
                ckv = ckvText,
                wcnt = wcntText,
                maca = macaText,
                accessCode = accessCode,
                spad0AccessCode = spad0AccessCode,
                konamiCardNumber = konamiCardNumber,
                privateNetworkNumber = privateNetworkNumber,
                spad0DecodeError = spad0DecodeError,
                accessCodeMatchesSpad0 = accessCodeMatchesSpad0,
                error = null,
            ),
        )
    }

    private fun handleMifare(card: MifareClassic) {
        val tagId = card.tag.id.toDisplayHex(":")
        val message = "公开源码不包含本地卡号计算逻辑\nIDM: $tagId"
        showResult(getString(R.string.mifare), message)
        saveLastScan(getString(R.string.mifare), message)
    }

    private fun postCardPayload(payload: JSONObject): JSONObject {
        val endpoint = cardServerUrl.toPostEndpoint()
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 5_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")

            connection.outputStream.bufferedWriter(StandardCharsets.UTF_8).use { writer ->
                writer.write(payload.toString())
            }

            val statusCode = connection.responseCode
            val stream = if (statusCode in 200..299) {
                connection.inputStream
            } else {
                connection.errorStream
            }
            val responseBody = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }
                .orEmpty()

            if (statusCode !in 200..299 && !responseBody.contains("\"code\"")) {
                val detail = runCatching {
                    JSONObject(responseBody).opt("detail")?.toString()
                }.getOrNull() ?: responseBody
                throw IOException("中转端 HTTP $statusCode: $detail")
            }

            return JSONObject(responseBody)
        } finally {
            connection.disconnect()
        }
    }

    private fun showResult(title: String, message: String) {
        runOnUiThread {
            latestCard = null
            canSaveLatestCard = false
            scanSnapshot = null
            fallbackResult = title to message
        }
    }

    private fun showSnapshot(snapshot: ScanSnapshot, persist: Boolean = true) {
        lastSnapshot = snapshot
        runOnUiThread {
            fallbackResult = null
            scanSnapshot = snapshot
            canSaveLatestCard = latestCard != null && snapshot.error == null
        }
        if (persist) {
            saveLastScan(snapshot.title, snapshot.toDisplayText(false))
        }
    }

    private fun renderLastSnapshot() {
        lastSnapshot?.let { showSnapshot(it, persist = false) }
    }

    private fun privacyEnabled(): Boolean =
        preferences.getBoolean("privacy_display", false)

    private fun upsertSavedCard(card: SavedAimeCard) {
        val cards = loadSavedCards().toMutableList()
        val index = cards.indexOfFirst { it.idm.equals(card.idm, ignoreCase = true) }
        if (index >= 0) {
            cards[index] = card.copy(label = cards[index].label)
        } else {
            cards.add(0, card)
        }
        saveSavedCards(cards)
    }

    private fun refreshSavedCards() {
        savedCards = loadSavedCards()
    }

    private fun renderSavedCards() {
        refreshSavedCards()
    }

    private fun loadSavedCards(): List<SavedAimeCard> {
        val raw = preferences.getString("saved_cards", null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                SavedAimeCard.fromJson(array.getJSONObject(index))
            }
        }.getOrDefault(emptyList())
    }

    private fun saveSavedCards(cards: List<SavedAimeCard>) {
        val array = JSONArray()
        cards.forEach { array.put(it.toJson()) }
        preferences.edit().putString("saved_cards", array.toString()).apply()
    }

    private fun loadRemoteServers(): List<RemoteServer> {
        val raw = preferences.getString("remote_servers", null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                RemoteServer.fromJson(array.getJSONObject(index))
            }
        }.getOrDefault(emptyList())
    }

    private fun saveRemoteServers(servers: List<RemoteServer>) {
        val array = JSONArray()
        servers.forEach { array.put(it.toJson()) }
        preferences.edit().putString("remote_servers", array.toString()).apply()
    }

    private fun appendDebugLog(message: String) {
        val logs = EncryptedDebugLogStore.load(this).toMutableList()
        logs.add(0, "[${System.currentTimeMillis()}] $message")
        EncryptedDebugLogStore.save(this, logs.take(200))
    }

    private fun uploadDebugLogs() {
        val logs = EncryptedDebugLogStore.load(this)
        if (logs.isEmpty()) {
            uploadLogStatus = getString(R.string.upload_no_logs)
            return
        }
        val endpoint = cardServerUrl.trim().takeIf { serverMode == MODE_REMOTE && it.isNotEmpty() }
        if (endpoint == null) {
            uploadLogStatus = getString(R.string.no_remote_server)
            return
        }
        uploadLogStatus = "正在上传…"
        Thread {
            try {
                val payload = JSONObject().apply {
                    put("appVersion", BuildConfig.VERSION_NAME)
                    put("build", BuildConfig.VERSION_CODE.toString())
                    put("platform", "Android")
                    put("createdAt", System.currentTimeMillis().toString())
                    put("logs", JSONArray(logs))
                }
                val envelope = JSONObject().apply {
                    put("payload", DebugLogCrypto.encryptToBase64(payload.toString().toByteArray(StandardCharsets.UTF_8)))
                }
                val connection = URL(endpoint.toPostEndpoint().siblingEndpoint("debug-log")).openConnection() as HttpURLConnection
                try {
                    connection.requestMethod = "POST"
                    connection.connectTimeout = 5_000
                    connection.readTimeout = 15_000
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    connection.outputStream.bufferedWriter(StandardCharsets.UTF_8).use {
                        it.write(envelope.toString())
                    }
                    if (connection.responseCode !in 200..299) {
                        throw IOException("HTTP ${connection.responseCode}")
                    }
                } finally {
                    connection.disconnect()
                }
                runOnUiThread { uploadLogStatus = getString(R.string.upload_success) }
            } catch (exc: Exception) {
                runOnUiThread { uploadLogStatus = exc.message ?: exc.javaClass.simpleName }
            }
        }.start()
    }

    private fun String.maskIfNeeded(): String =
        if (privacyEnabled()) maskLastFour() else this

    private fun saveLastScan(title: String, message: String) {
        preferences.edit()
            .putString("last_card_title", title)
            .putString("last_card_message", message)
            .apply()
    }

    private fun restoreLastScan() {
        val lastTitle = preferences.getString("last_card_title", null) ?: return
        val lastMessage = preferences.getString("last_card_message", null)
            ?: getString(R.string.scan_hint)
        showResult(lastTitle, lastMessage)
    }
}

data class ScanSnapshot(
    val title: String,
    val code: String?,
    val idm: String,
    val ckv: String,
    val wcnt: String,
    val maca: String,
    val accessCode: String,
    val spad0AccessCode: String? = null,
    val konamiCardNumber: String? = null,
    val privateNetworkNumber: String? = null,
    val spad0DecodeError: String? = null,
    val accessCodeMatchesSpad0: Boolean? = null,
    val error: String?,
) {
    fun toDisplayText(privateMode: Boolean): String {
        fun mask(value: String) = if (privateMode) value.maskLastFour() else value
        return buildString {
            appendLine("IDM: ${mask(idm)}")
            appendLine("Access Code: ${mask(accessCode.groupEvery4())}")
            if (!privateNetworkNumber.isNullOrBlank()) {
                appendLine("Private Network: ${mask(privateNetworkNumber.groupEvery4())}")
            }
            if (!konamiCardNumber.isNullOrBlank()) {
                appendLine("Konami Card Number: ${mask(konamiCardNumber.groupEvery4())}")
            }
            if (!spad0DecodeError.isNullOrBlank()) {
                appendLine("Access Code 解析失败: $spad0DecodeError")
            }
            accessCodeMatchesSpad0?.let {
                appendLine(if (it) "Verity Success" else "Verity Failed")
            }
            if (!error.isNullOrBlank()) {
                append("ERROR: $error")
            }
        }.trimEnd()
    }
}

data class SavedAimeCard(
    val label: String,
    val code: String?,
    val idm: String,
    val accessCode: String,
    val konamiCardNumber: String?,
    val privateNetworkNumber: String?,
    val cardType: String,
    val updatedAt: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("label", label)
        code?.let { put("code", it) }
        put("idm", idm)
        put("accessCode", accessCode)
        konamiCardNumber?.let { put("konamiCardNumber", it) }
        privateNetworkNumber?.let { put("privateNetworkNumber", it) }
        put("cardType", cardType)
        put("updatedAt", updatedAt)
    }

    companion object {
        fun fromJson(value: JSONObject): SavedAimeCard? {
            val code = value.optNonBlankString("code")
            val idm = value.optString("idm")
            val accessCode = value.optString("accessCode")
            if (idm.isBlank() || accessCode.isBlank()) return null
            return SavedAimeCard(
                label = value.optString("label", "AiMe 卡"),
                code = code,
                idm = idm,
                accessCode = accessCode,
                konamiCardNumber = value.optNonBlankString("konamiCardNumber"),
                privateNetworkNumber = value.optNonBlankString("privateNetworkNumber"),
                cardType = value.optString("cardType", "FeliCa"),
                updatedAt = value.optLong("updatedAt", 0L),
            )
        }
    }
}

data class RemoteServer(
    val name: String,
    val url: String,
    val publicKey: String,
) {
    val displayName: String
        get() = name.ifBlank { "未命名服务器" }

    fun toJson(): JSONObject = JSONObject().apply {
        put("name", name)
        put("url", url)
        put("publicKey", publicKey)
    }

    companion object {
        fun fromJson(value: JSONObject): RemoteServer? {
            val url = value.optString("url")
            val publicKey = value.optString("publicKey")
            if (url.isBlank() || publicKey.isBlank()) return null
            return RemoteServer(
                name = value.optString("name", "未命名服务器"),
                url = url,
                publicKey = publicKey,
            )
        }
    }
}

private object Spad0Rsa {
    fun validate(publicKey: String) {
        makePublicKey(publicKey)
    }

    fun encrypt(plaintext: ByteArray, publicKey: String): String {
        if (plaintext.size != 16) throw IOException("缺少可上传的卡片安全数据")
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            makePublicKey(publicKey),
            OAEPParameterSpec(
                "SHA-256",
                "MGF1",
                MGF1ParameterSpec.SHA256,
                PSource.PSpecified.DEFAULT,
            ),
        )
        return Base64.encodeToString(cipher.doFinal(plaintext), Base64.NO_WRAP)
    }

    private fun makePublicKey(publicKey: String): PublicKey {
        val body = publicKey
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .filterNot { it.isWhitespace() }
        if (body.isBlank()) throw IOException("请先配置远端服务器 RSA 公钥")
        val der = try {
            Base64.decode(body, Base64.DEFAULT)
        } catch (exc: IllegalArgumentException) {
            throw IOException("RSA 公钥不是有效 Base64", exc)
        }
        return try {
            KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(der))
        } catch (exc: Exception) {
            throw IOException("RSA 公钥格式无效", exc)
        }
    }
}

private object EncryptedDebugLogStore {
    private const val KEY = "encrypted_debug_logs"

    fun load(context: Context): List<String> {
        val encoded = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
            .getString(KEY, null)
            ?: return emptyList()
        return runCatching {
            val plaintext = DebugLogCrypto.decryptFromBase64(encoded)
            val array = JSONArray(String(plaintext, StandardCharsets.UTF_8))
            (0 until array.length()).map { array.getString(it) }
        }.getOrDefault(emptyList())
    }

    fun save(context: Context, logs: List<String>) {
        val preferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        if (logs.isEmpty()) {
            preferences.edit().remove(KEY).apply()
            return
        }
        val data = JSONArray(logs).toString().toByteArray(StandardCharsets.UTF_8)
        preferences.edit()
            .putString(KEY, DebugLogCrypto.encryptToBase64(data))
            .apply()
    }
}

private object DebugLogCrypto {
    private const val SECRET = "NFCAimeDebugLog-v1"

    fun encryptToBase64(plaintext: ByteArray): String {
        val nonce = ByteArray(12)
        SecureRandom().nextBytes(nonce)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(), GCMParameterSpec(128, nonce))
        val ciphertext = cipher.doFinal(plaintext)
        return Base64.encodeToString(nonce + ciphertext, Base64.NO_WRAP)
    }

    fun decryptFromBase64(encoded: String): ByteArray {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        require(combined.size > 28) { "encrypted debug log is too short" }
        val nonce = combined.copyOfRange(0, 12)
        val ciphertext = combined.copyOfRange(12, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, nonce))
        return cipher.doFinal(ciphertext)
    }

    private fun key(): SecretKeySpec {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(SECRET.toByteArray(StandardCharsets.UTF_8))
        return SecretKeySpec(digest, "AES")
    }
}

inline fun <T : TagTechnology, R> T.use(block: (T) -> R): R = (this as Closeable).use {
    connect()
    block(this)
}

private fun ByteArray.toHex(): String = joinToString("") {
    "%02x".format(it.toInt() and 0xff)
}

private fun ByteArray.toDisplayHex(separator: String = " "): String = toHex()
    .uppercase()
    .chunked(2)
    .joinToString(separator)

fun String.groupEvery4(): String {
    val compact = filterNot { it.isWhitespace() }
    if (compact.length <= 4) return this
    return compact.chunked(4).joinToString(" ")
}

fun String.maskLastFour(): String {
    var remaining = count { it.isLetterOrDigit() }.coerceAtMost(4)
    return reversed().map { char ->
        when {
            !char.isLetterOrDigit() -> char
            remaining > 0 -> {
                remaining -= 1
                char
            }
            else -> '•'
        }
    }.joinToString("").reversed()
}

private fun JSONObject.optNonBlankString(name: String): String? {
    if (!has(name) || isNull(name)) return null
    return optString(name).takeIf { it.isNotBlank() && it != "null" }
}

private fun JSONObject.optNullableBoolean(name: String): Boolean? {
    if (!has(name) || isNull(name)) return null
    return optBoolean(name)
}

private fun String.toPostEndpoint(): String {
    val value = trim().trimEnd('/')
    if (value.isEmpty()) throw IOException("POST URL 不能为空")

    val baseUrl = if (value.startsWith("http://") || value.startsWith("https://")) {
        value
    } else {
        "https://$value"
    }
    val parsed = try {
        URL(baseUrl)
    } catch (exc: Exception) {
        throw IOException("POST URL 格式无效: $value", exc)
    }
    if (parsed.host.isNullOrBlank()) throw IOException("POST URL 格式无效: $value")
    val pathParts = parsed.path
        .split("/")
        .filter { it.isNotBlank() }
    if (pathParts.lastOrNull() !in setOf("card", "refeash-aime")) {
        val path = "/" + (pathParts + "card").joinToString("/")
        return URL(parsed.protocol, parsed.host, parsed.port, path).toString()
    }
    return parsed.toString()
}

private fun String.siblingEndpoint(lastPathComponent: String): String {
    val parsed = URL(this)
    val pathParts = parsed.path
        .split("/")
        .filter { it.isNotBlank() }
        .dropLast(1) + lastPathComponent
    return URL(parsed.protocol, parsed.host, parsed.port, "/" + pathParts.joinToString("/")).toString()
}

private fun Context.networkHintText(): String {
    val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val network = connectivity.activeNetwork
    val capabilities = connectivity.getNetworkCapabilities(network)
    return when {
        capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> {
            val ip = wifiIpv4Address()
            if (ip == null) {
                "当前是 Wi-Fi。请填写运行 server 的电脑局域网 IP；手机不能使用 127.0.0.1。"
            } else {
                "当前是 Wi-Fi，本机 IP：$ip。请填写运行 server 的电脑局域网 IP；手机不能使用 127.0.0.1。"
            }
        }
        capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true ->
            "当前是蜂窝网络。本地电脑服务通常不可达，请使用远端服务器、公网地址或内网穿透地址。"
        else ->
            "未检测到 Wi-Fi。若要连接本地电脑服务，请确认手机和电脑在同一可互通网络。"
    }
}

private fun Context.wifiIpv4Address(): String? {
    @Suppress("DEPRECATION")
    val ip = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
        .connectionInfo
        .ipAddress
    if (ip == 0) return null
    return listOf(
        ip and 0xff,
        ip shr 8 and 0xff,
        ip shr 16 and 0xff,
        ip shr 24 and 0xff,
    ).joinToString(".")
}

private fun ByteArray.requireFelicaWriteSuccess(): ByteArray {
    if (size < 12 || (this[1].toInt() and 0xff) != 0x09) {
        throw IOException("FeliCa 写入响应格式错误")
    }
    if (this[10].toInt() != 0 || this[11].toInt() != 0) {
        throw IOException(
            "FeliCa 写入失败: %02X %02X".format(
                this[10].toInt() and 0xff,
                this[11].toInt() and 0xff,
            ),
        )
    }
    return this
}

private fun ByteArray.extractFelicaBlocks(expectedBlockCount: Int): ByteArray {
    if (size < 13 || (this[1].toInt() and 0xff) != 0x07) {
        throw IOException("FeliCa 读取响应格式错误")
    }
    if (this[10].toInt() != 0 || this[11].toInt() != 0) {
        throw IOException(
            "FeliCa 读取失败: %02X %02X".format(
                this[10].toInt() and 0xff,
                this[11].toInt() and 0xff,
            ),
        )
    }

    val blockCount = this[12].toInt() and 0xff
    if (blockCount != expectedBlockCount) {
        throw IOException("FeliCa 返回 $blockCount 个块，预期 $expectedBlockCount 个")
    }
    val dataEnd = 13 + blockCount * 16
    if (size < dataEnd) {
        throw IOException("FeliCa 块数据不完整")
    }
    return copyOfRange(13, dataEnd)
}

fun NfcF.readWithoutEncryption(block: Int, vararg more: Int): ByteArray =
    with(ByteArrayOutputStream()) {
        val all = intArrayOf(block, *more)
        write(0)
        write(0x06)
        write(tag.id, 0, 8)
        write(1)
        write(0x0b)
        write(0x00)
        write(all.size)
        all.forEach {
            write(0x80)
            write(it)
        }
        toByteArray().apply { set(0, size.toByte()) }
    }.let { transceive(it) }

fun NfcF.writeWithoutEncryption(
    blockDataPair: Pair<Int, ByteArray>,
    vararg more: Pair<Int, ByteArray>,
): ByteArray = with(ByteArrayOutputStream()) {
    val all = listOf(blockDataPair, *more)
    write(0)
    write(0x08)
    write(tag.id, 0, 8)
    write(1)
    write(0x09)
    write(0x00)
    write(all.size)
    all.forEach { (blockNum, _) ->
        write(0x80)
        write(blockNum)
    }
    all.forEach { (_, data) ->
        require(data.size == 16) { "Each data block must be 16 bytes" }
        write(data)
    }
    toByteArray().apply { set(0, size.toByte()) }
}.let { transceive(it) }
