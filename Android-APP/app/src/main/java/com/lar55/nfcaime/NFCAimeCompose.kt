package com.lar55.nfcaime

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CreditCard
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Nfc
import androidx.compose.material.icons.rounded.Save
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material.icons.rounded.UploadFile
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

enum class AppSection {
    Scan,
    Cards,
    About,
}

enum class ScanMode {
    Local,
    Remote,
}

data class NFCAimeUiState(
    val section: AppSection,
    val scanMode: ScanMode,
    val privacyDisplay: Boolean,
    val snapshot: ScanSnapshot?,
    val fallbackResult: Pair<String, String>?,
    val savedCards: List<SavedAimeCard>,
    val remoteServers: List<RemoteServer>,
    val selectedRemoteServerUrl: String,
    val serverDraftName: String,
    val serverDraftUrl: String,
    val serverDraftPublicKey: String,
    val serverStatus: String,
    val uploadLogStatus: String,
    val canSaveLatestCard: Boolean,
    val appVersion: String,
    val versionCode: Int,
)

data class NFCAimeUiActions(
    val onSectionChange: (AppSection) -> Unit,
    val onScanModeChange: (ScanMode) -> Unit,
    val onPrivacyDisplayChange: (Boolean) -> Unit,
    val onServerSelected: (String) -> Unit,
    val onServerNameChange: (String) -> Unit,
    val onServerUrlChange: (String) -> Unit,
    val onServerPublicKeyChange: (String) -> Unit,
    val onSaveServer: () -> Unit,
    val onSaveLatestCard: () -> Unit,
    val onClearCards: () -> Unit,
    val onOpenReleases: () -> Unit,
    val onUploadLogs: () -> Unit,
    val onStartRead: () -> Unit,
)

@Composable
fun NFCAimeApp(state: NFCAimeUiState, actions: NFCAimeUiActions) {
    val dark = isSystemInDarkTheme()
    MaterialTheme(
        colorScheme = if (dark) darkScheme else lightScheme,
    ) {
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            bottomBar = {
                Surface(color = MaterialTheme.colorScheme.surface, tonalElevation = 6.dp) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        BottomItem("刷卡", Icons.Rounded.Nfc, AppSection.Scan, state, actions)
                        BottomItem("我的卡", Icons.Rounded.CreditCard, AppSection.Cards, state, actions)
                        BottomItem("关于", Icons.Rounded.Info, AppSection.About, state, actions)
                    }
                }
            },
        ) { padding ->
            Surface(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.background)
                    .padding(padding),
                color = MaterialTheme.colorScheme.background,
            ) {
                when (state.section) {
                    AppSection.Scan -> ScanScreen(state, actions)
                    AppSection.Cards -> CardsScreen(state, actions)
                    AppSection.About -> AboutScreen(state, actions)
                }
            }
        }
    }
}

@Composable
private fun RowScope.BottomItem(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    section: AppSection,
    state: NFCAimeUiState,
    actions: NFCAimeUiActions,
) {
    val selected = state.section == section
    if (selected) {
        Button(
            onClick = { actions.onSectionChange(section) },
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(18.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
        ) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(label, maxLines = 1)
        }
    } else {
        TextButton(
            onClick = { actions.onSectionChange(section) },
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(18.dp),
            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
        ) {
            Icon(icon, contentDescription = label, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(label, maxLines = 1)
        }
    }
}

@Composable
private fun ScanScreen(state: NFCAimeUiState, actions: NFCAimeUiActions) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item { ScreenHeader(title = "刷卡", subtitle = "读取 AiMe 卡片") }
        item { ServerModeCard(state, actions) }
        item {
            Button(
                onClick = actions.onStartRead,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(58.dp),
                shape = RoundedCornerShape(28.dp),
            ) {
                Icon(Icons.Rounded.Nfc, contentDescription = null)
                Spacer(Modifier.width(10.dp))
                Text("开始读卡", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            }
        }
        item {
            when {
                state.snapshot != null -> ScanResultCard(state.snapshot, state.privacyDisplay, state.canSaveLatestCard, actions)
                state.fallbackResult != null -> FallbackResultCard(state.fallbackResult)
                else -> EmptyResultCard()
            }
        }
        if (state.savedCards.isNotEmpty()) {
            item {
                EarlierRecordsCard(
                    cards = state.savedCards.take(5),
                    privacy = state.privacyDisplay,
                )
            }
        }
    }
}

@Composable
private fun ServerModeCard(state: NFCAimeUiState, actions: NFCAimeUiActions) {
    ContentCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Settings, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(10.dp))
            Text("服务器设置", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ModeButton("本地读取", state.scanMode == ScanMode.Local) {
                actions.onScanModeChange(ScanMode.Local)
            }
            ModeButton("远端服务器", state.scanMode == ScanMode.Remote) {
                actions.onScanModeChange(ScanMode.Remote)
            }
        }
        Spacer(Modifier.height(14.dp))
        if (state.scanMode == ScanMode.Local) {
            HintBlock(
                title = "点击下方读取你的卡片信息内容",
                body = "如需实现其他功能需要配置对应远端服务器",
            )
        } else {
            Text(
                "选择一个由您自行添加配置的服务器",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(12.dp))
            if (state.remoteServers.isEmpty()) {
                Text(
                    "暂无服务器，先添加一个远端地址",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    state.remoteServers.forEach { server ->
                        OutlinedButton(
                            onClick = { actions.onServerSelected(server.url) },
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(16.dp),
                        ) {
                            Text(
                                server.displayName,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (server.url == state.selectedRemoteServerUrl) {
                                AssistChip(onClick = {}, label = { Text("已选择") })
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(14.dp))
            OutlinedTextField(
                value = state.serverDraftName,
                onValueChange = actions.onServerNameChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("服务器名称") },
                singleLine = true,
            )
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(
                value = state.serverDraftUrl,
                onValueChange = actions.onServerUrlChange,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("服务器地址") },
                placeholder = { Text("https://domain/aime_reader/card") },
                singleLine = true,
            )
            Spacer(Modifier.height(10.dp))
            OutlinedTextField(
                value = state.serverDraftPublicKey,
                onValueChange = actions.onServerPublicKeyChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(150.dp),
                label = { Text("RSA 公钥") },
                placeholder = { Text("粘贴服务器提供的 PEM 公钥") },
                minLines = 4,
                maxLines = 6,
            )
            Spacer(Modifier.height(12.dp))
            Button(
                onClick = actions.onSaveServer,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(18.dp),
            ) {
                Icon(Icons.Rounded.Save, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("保存服务器")
            }
            Spacer(Modifier.height(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Key, contentDescription = null, tint = successColor)
                Spacer(Modifier.width(8.dp))
                Text(
                    "卡片数据将使用该服务器Key加密上传",
                    color = successColor,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (state.serverStatus.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    state.serverStatus,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Spacer(Modifier.height(16.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("隐私显示", fontWeight = FontWeight.Bold)
                Text(
                    "默认只显示 IDM 和访问码最后 4 位",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Switch(checked = state.privacyDisplay, onCheckedChange = actions.onPrivacyDisplayChange)
        }
    }
}

@Composable
private fun RowScope.ModeButton(label: String, selected: Boolean, onClick: () -> Unit) {
    if (selected) {
        Button(
            onClick = onClick,
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(18.dp),
        ) {
            Text(label)
        }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = Modifier.weight(1f),
            shape = RoundedCornerShape(18.dp),
        ) {
            Text(label)
        }
    }
}

@Composable
private fun HintBlock(title: String, body: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(18.dp))
            .padding(14.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, color = MaterialTheme.colorScheme.onSurface)
            Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun ScanResultCard(
    snapshot: ScanSnapshot,
    privacy: Boolean,
    canSave: Boolean,
    actions: NFCAimeUiActions,
) {
    ContentCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .background(successColor.copy(alpha = 0.15f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text("✓", color = successColor, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(10.dp))
            Text("最近结果", color = successColor, fontWeight = FontWeight.Bold, fontSize = 20.sp)
        }
        Spacer(Modifier.height(14.dp))
        CopyRow("IDM", snapshot.idm, privacy)
        CopyRow("Access Code", snapshot.accessCode.groupEvery4(), privacy)
        snapshot.privateNetworkNumber?.let { CopyRow("Private Network", it.groupEvery4(), privacy) }
        snapshot.konamiCardNumber?.let { CopyRow("Konami Card Number", it.groupEvery4(), privacy) }
        if (!snapshot.spad0DecodeError.isNullOrBlank()) {
            Spacer(Modifier.height(8.dp))
            Text("Access Code 解析失败: ${snapshot.spad0DecodeError}", color = MaterialTheme.colorScheme.error)
        }
        snapshot.accessCodeMatchesSpad0?.let {
            Spacer(Modifier.height(10.dp))
            Text(
                if (it) "Verity Success" else "Verity Failed",
                color = if (it) successColor else MaterialTheme.colorScheme.error,
                fontWeight = FontWeight.Bold,
            )
        }
        if (!snapshot.error.isNullOrBlank()) {
            Spacer(Modifier.height(10.dp))
            Text("ERROR: ${snapshot.error}", color = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.height(12.dp))
        Text(
            "长按 IDM、Access Code 或 Konami Card Number 可复制",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = actions.onSaveLatestCard,
            enabled = canSave,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(18.dp),
        ) {
            Text(if (canSave) "保存卡片" else "已保存")
        }
    }
}

@Composable
private fun FallbackResultCard(result: Pair<String, String>) {
    ContentCard {
        Text(result.first, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text(result.second, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun EmptyResultCard() {
    ContentCard {
        Text("等待读卡", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("请贴近 NFC 卡片，读卡结果会显示在这里", color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun EarlierRecordsCard(cards: List<SavedAimeCard>, privacy: Boolean) {
    ContentCard {
        Text("更早记录", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        cards.forEachIndexed { index, card ->
            if (index > 0) HorizontalDivider(modifier = Modifier.padding(vertical = 10.dp))
            Text(card.label, fontWeight = FontWeight.Bold)
            Text("IDM: ${maskValue(card.idm, privacy)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun CardsScreen(state: NFCAimeUiState, actions: NFCAimeUiActions) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        item { ScreenHeader(title = "我的卡", subtitle = "本地保存的卡片数据") }
        if (state.savedCards.isEmpty()) {
            item {
                ContentCard {
                    Text("还没有保存的卡", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(6.dp))
                    Text("刷卡成功后点击保存卡片", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            items(state.savedCards.size) { index ->
                SavedCardView(card = state.savedCards[index], privacy = state.privacyDisplay)
            }
            item {
                OutlinedButton(
                    onClick = actions.onClearCards,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Icon(Icons.Rounded.Delete, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("清空保存记录")
                }
            }
        }
    }
}

@Composable
private fun SavedCardView(card: SavedAimeCard, privacy: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        AimeCardFace(card)
        Spacer(Modifier.height(14.dp))
        ContentCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Issued by", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Text("SEGA", style = MaterialTheme.typography.titleLarge)
                }
                AssistChip(onClick = {}, label = { Text("Amusement IC") })
            }
            Spacer(Modifier.height(14.dp))
            CopyRow("IDM", card.idm, privacy)
            CopyRow("Access Code", card.accessCode.groupEvery4(), privacy)
            card.privateNetworkNumber?.let { CopyRow("Private Network", it.groupEvery4(), privacy) }
            card.konamiCardNumber?.let { CopyRow("Konami Card Number", it.groupEvery4(), privacy) }
            Spacer(Modifier.height(8.dp))
            Text("卡类型：${card.cardType}", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun AimeCardFace(card: SavedAimeCard) {
    Card(
        modifier = Modifier
            .widthIn(max = 330.dp)
            .fillMaxWidth()
            .height(190.dp),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            Color(0xFFFAFAFA),
                            Color(0xFFEAF7FF),
                            Color(0xFFD7F4FF),
                        ),
                    ),
                )
                .padding(20.dp),
        ) {
            Text("AiMe", color = Color(0xFF1F2937), fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Text(
                card.accessCode.groupEvery4(),
                color = Color(0xFF0F172A),
                fontFamily = FontFamily.Monospace,
                fontSize = 18.sp,
                modifier = Modifier.align(Alignment.BottomStart),
            )
        }
    }
}

@Composable
private fun AboutScreen(state: NFCAimeUiState, actions: NFCAimeUiActions) {
    val uriHandler = LocalUriHandler.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item { ScreenHeader(title = "关于", subtitle = "版本、更新与错误日志") }
        item {
            ContentCard {
                Text("NFCAiME", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                Text("版本：${state.appVersion} (${state.versionCode})")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("开发：")
                    TextButton(onClick = { uriHandler.openUri("https://github.com/Project-HashCat") }) {
                        Text("HashCat Team")
                    }
                }
                Text("当前平台：Android")
            }
        }
        item {
            ContentCard {
                Text("本次更新", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                Text("自定义远端服务器、RSA 加密上传、本地读取与卡包保存")
                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = actions.onOpenReleases,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Icon(Icons.Rounded.SystemUpdate, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("检查更新")
                }
            }
        }
        item {
            ContentCard {
                Text("错误日志", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                Text("错误日志只会在你手动点击后上传", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(14.dp))
                OutlinedButton(
                    onClick = actions.onUploadLogs,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Icon(Icons.Rounded.UploadFile, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("上传错误日志")
                }
                if (state.uploadLogStatus.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(state.uploadLogStatus, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun ScreenHeader(title: String, subtitle: String) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(4.dp))
        Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ContentCard(content: @Composable ColumnScope.() -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(modifier = Modifier.padding(18.dp), content = content)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CopyRow(label: String, value: String, privacy: Boolean) {
    val clipboard = LocalClipboardManager.current
    val displayValue = maskValue(value, privacy)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = {},
                onLongClick = { clipboard.setText(AnnotatedString(value)) },
            )
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(0.9f),
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            displayValue,
            modifier = Modifier.weight(1.35f),
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

private fun maskValue(value: String, privacy: Boolean): String =
    if (privacy) value.maskLastFour() else value

private val successColor = Color(0xFF22C55E)

private val darkScheme = darkColorScheme(
    primary = Color(0xFF22D3EE),
    secondary = successColor,
    background = Color(0xFF05070F),
    surface = Color(0xFF17181C),
    surfaceVariant = Color(0xFF25272E),
    onSurface = Color(0xFFF8FAFC),
    onSurfaceVariant = Color(0xFFA8AFBD),
)

private val lightScheme = lightColorScheme(
    primary = Color(0xFF0A84FF),
    secondary = successColor,
    background = Color(0xFFF5F7FB),
    surface = Color.White,
    surfaceVariant = Color(0xFFE9EDF5),
    onSurface = Color(0xFF101828),
    onSurfaceVariant = Color(0xFF667085),
)
