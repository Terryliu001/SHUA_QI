package com.shuaqi.shuaqi

import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 主 Activity。除了 Flutter 默认桥，只额外提供两个"落盘到系统"的通道：
 * 保存题目图片到相册（`saveImage`）与导出 PDF 到下载目录（`savePdf`）。
 *
 * 为什么不引第三方文件库：需求只有"写一个文件到用户能找到的地方"，
 * MediaStore 在 Android 10+ 不需要存储权限，几十行 Kotlin 比加一个依赖更稳。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CHANNEL,
        ).setMethodCallHandler { call, result ->
            val bytes = call.argument<ByteArray>("bytes")
            when (call.method) {
                "saveImage" -> {
                    val name = call.argument<String>("name") ?: "shuaqi_question.png"
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("bad_args", "bytes is required", null)
                    } else {
                        try {
                            result.success(saveImage(bytes, name))
                        } catch (error: Exception) {
                            result.error("save_failed", error.message, null)
                        }
                    }
                }
                // 2026-10-25：导出 PDF。Android 10+ 走 MediaStore.Downloads
                // （用户能在「下载/SHUAQI」里看到）；低版本退回应用外部目录。
                "savePdf" -> {
                    val name = call.argument<String>("name") ?: "shuaqi_export.pdf"
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("bad_args", "bytes is required", null)
                    } else {
                        try {
                            result.success(savePdf(bytes, name))
                        } catch (error: Exception) {
                            result.error("save_failed", error.message, null)
                        }
                    }
                }
                // 2026-10-26：备份 zip。文件可能上百 MB，所以**按路径流式复制**，
                // 不把字节读进内存再走通道。
                "saveFile" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "shuaqi_backup.zip"
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    if (path.isNullOrEmpty() || !File(path).exists()) {
                        result.error("bad_args", "path is required", null)
                    } else {
                        try {
                            result.success(saveFile(path, name, mime))
                        } catch (error: Exception) {
                            result.error("save_failed", error.message, null)
                        }
                    }
                }
                // 2026-10-26：恢复备份后重启（数据库文件被整体换掉，进程里的
                // 旧句柄指向的是被替换前的 inode，不重启读到的还是旧数据）。
                "restartApp" -> {
                    try {
                        restartApp()
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("restart_failed", error.message, null)
                    }
                }
                // 2026-10-27：反馈要带"什么设备/什么系统"，这里给一个只含
                // 厂商型号 + Android 版本 + API 级别的最小集合（不取任何标识符）。
                "deviceInfo" -> {
                    try {
                        result.success(
                            mapOf(
                                "model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
                                "android" to Build.VERSION.RELEASE,
                                "sdk" to Build.VERSION.SDK_INT,
                            )
                        )
                    } catch (error: Exception) {
                        result.error("device_info_failed", error.message, null)
                    }
                }
                // 2026-10-28 v0.1.3：备份文件查看与管理（只在「下载/SHUAQI」里
                // 本应用创建的 SHUAQI_*.zip，不碰用户其它文件）。
                "listBackups" -> {
                    try {
                        result.success(listBackups())
                    } catch (error: Exception) {
                        result.error("list_backups_failed", error.message, null)
                    }
                }
                "renameBackup" -> {
                    val uri = call.argument<String>("uri")
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    if (name.isNullOrEmpty() || (uri.isNullOrEmpty() && path.isNullOrEmpty())) {
                        result.error("bad_args", "name and uri/path are required", null)
                    } else {
                        try {
                            result.success(renameBackup(uri, path, name))
                        } catch (error: Exception) {
                            result.error("rename_backup_failed", error.message, null)
                        }
                    }
                }
                "deleteBackup" -> {
                    val uri = call.argument<String>("uri")
                    val path = call.argument<String>("path")
                    try {
                        result.success(deleteBackup(uri, path))
                    } catch (error: Exception) {
                        result.error("delete_backup_failed", error.message, null)
                    }
                }
                "importBackupToCache" -> {
                    val uri = call.argument<String>("uri")
                    val path = call.argument<String>("path")
                    try {
                        result.success(importBackupToCache(uri, path))
                    } catch (error: Exception) {
                        result.error("import_backup_failed", error.message, null)
                    }
                }
                // 打开外链（GitHub Releases / 历史版本）。不新增 url_launcher 依赖。
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("bad_args", "url is required", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("open_url_failed", error.message, null)
                        }
                    }
                }
                // 2026-10-28 v0.1.3：应用内更新（GitHub Releases 下载后覆盖安装）。
                "canInstallApk" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty() || !File(path).exists()) {
                        result.error("bad_args", "APK path is required", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("install_apk_failed", error.message, null)
                        }
                    }
                }
                "openUnknownSourcesSettings" -> {
                    try {
                        openUnknownSourcesSettings()
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("open_settings_failed", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveImage(bytes: ByteArray, displayName: String): String {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/SHUAQI")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = contentResolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values,
        ) ?: throw IllegalStateException("MediaStore insert failed")
        contentResolver.openOutputStream(uri)?.use { stream ->
            stream.write(bytes)
            stream.flush()
        } ?: throw IllegalStateException("MediaStore openOutputStream failed")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        }
        return uri.toString()
    }

    /**
     * 写一份 PDF 到「下载」。返回给用户看的落点（uri 或绝对路径）。
     *
     * Android 10+ 用 MediaStore.Downloads：不需要任何权限，且用户能在系统
     * 「文件」的"下载"里直接看到。低于 10 没有 Downloads 集合（写入公共目录
     * 需要存储权限），所以退回应用自己的外部目录——文件管理器仍能打开。
     */
    private fun savePdf(bytes: ByteArray, displayName: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/SHUAQI")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: throw IllegalStateException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: throw IllegalStateException("MediaStore openOutputStream failed")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        val dir = File(
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            "SHUAQI",
        )
        if (!dir.exists()) {
            dir.mkdirs()
        }
        val file = File(dir, displayName)
        file.writeBytes(bytes)
        return file.absolutePath
    }

    /**
     * 把一个**已经存在的文件**流式复制到「下载」。
     *
     * 与 savePdf 的区别：备份 zip 可能上百 MB，走字节通道会把内存吃光，
     * 所以这里直接从源文件读流写进 MediaStore。
     */
    private fun saveFile(sourcePath: String, displayName: String, mime: String): String {
        val source = File(sourcePath)
        if (!source.exists()) {
            throw IllegalStateException("源文件不存在：$sourcePath")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/SHUAQI")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: throw IllegalStateException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)?.use { out ->
                source.inputStream().use { input -> input.copyTo(out) }
            } ?: throw IllegalStateException("MediaStore openOutputStream failed")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        }
        val dir = File(
            getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            "SHUAQI",
        )
        if (!dir.exists()) {
            dir.mkdirs()
        }
        val target = File(dir, displayName)
        source.inputStream().use { input ->
            target.outputStream().use { out -> input.copyTo(out) }
        }
        return target.absolutePath
    }

    /**
     * 备份文件列表：只返回「下载/SHUAQI」里本应用创建的 `SHUAQI_*.zip`。
     *
     * Android 10+ 走 MediaStore.Downloads（不需要存储权限）；Android 8/9
     * 没有公共 Downloads 集合的写权限，沿用跟 saveFile 一样的应用外部目录。
     */
    private fun listBackups(): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val projection = arrayOf(
                MediaStore.Downloads._ID,
                MediaStore.Downloads.DISPLAY_NAME,
                MediaStore.Downloads.SIZE,
                MediaStore.Downloads.DATE_MODIFIED,
                MediaStore.Downloads.OWNER_PACKAGE_NAME,
            )
            val selection =
                "${MediaStore.Downloads.RELATIVE_PATH} LIKE ? AND " +
                    "${MediaStore.Downloads.DISPLAY_NAME} LIKE ?"
            val args = arrayOf("Download/SHUAQI%", "SHUAQI_%.zip")
            contentResolver.query(collection, projection, selection, args, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.SIZE)
                val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Downloads.DATE_MODIFIED)
                val ownerCol = cursor.getColumnIndex(MediaStore.Downloads.OWNER_PACKAGE_NAME)
                while (cursor.moveToNext()) {
                    val name = cursor.getString(nameCol) ?: continue
                    if (!name.startsWith("SHUAQI_") || !name.endsWith(".zip", true)) {
                        continue
                    }
                    val id = cursor.getLong(idCol)
                    val uri = ContentUris.withAppendedId(collection, id)
                    val owner = if (ownerCol >= 0) cursor.getString(ownerCol) else null
                    out.add(
                        mapOf(
                            "uri" to uri.toString(),
                            "path" to "",
                            "name" to name,
                            "size" to cursor.getLong(sizeCol),
                            "modified" to cursor.getLong(dateCol) * 1000L,
                            "owned" to (owner == null || owner == packageName),
                        )
                    )
                }
            }
        } else {
            backupDir().listFiles()?.forEach { file ->
                if (file.isFile && file.name.startsWith("SHUAQI_") &&
                    file.name.endsWith(".zip", true)
                ) {
                    out.add(
                        mapOf(
                            "uri" to "",
                            "path" to file.absolutePath,
                            "name" to file.name,
                            "size" to file.length(),
                            "modified" to file.lastModified(),
                            "owned" to true,
                        )
                    )
                }
            }
        }
        return out
    }

    private fun renameBackup(uri: String?, path: String?, newName: String): Boolean {
        val safe = newName.trim().let {
            if (it.endsWith(".zip", true)) it else "$it.zip"
        }
        if (safe.isBlank() || safe == ".zip") {
            throw IllegalArgumentException("备份名不能为空")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !uri.isNullOrEmpty()) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, safe)
            }
            return contentResolver.update(Uri.parse(uri), values, null, null) > 0
        }
        if (path.isNullOrEmpty()) {
            throw IllegalArgumentException("找不到备份文件路径")
        }
        val source = File(path)
        if (!source.exists()) {
            throw IllegalStateException("备份文件不存在")
        }
        val target = File(source.parentFile, safe)
        if (target.exists()) {
            throw IllegalStateException("同名备份已存在")
        }
        return source.renameTo(target)
    }

    private fun deleteBackup(uri: String?, path: String?): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !uri.isNullOrEmpty()) {
            return contentResolver.delete(Uri.parse(uri), null, null) > 0
        }
        if (path.isNullOrEmpty()) {
            throw IllegalArgumentException("找不到备份文件路径")
        }
        val file = File(path)
        return !file.exists() || file.delete()
    }

    /** 把选中的备份复制到应用缓存，返回可交给 Dart 侧恢复的本地路径。 */
    private fun importBackupToCache(uri: String?, path: String?): String {
        if (!path.isNullOrEmpty() && File(path).exists()) {
            return path
        }
        if (uri.isNullOrEmpty()) {
            throw IllegalArgumentException("找不到备份文件")
        }
        val target = File(cacheDir, "shuaqi_restore_import.zip")
        if (target.exists()) {
            target.delete()
        }
        contentResolver.openInputStream(Uri.parse(uri))?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: throw IllegalStateException("读不到备份文件")
        return target.absolutePath
    }

    private fun backupDir(): File {
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "SHUAQI")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    /**
     * 拉起系统安装器。
     *
     * 安装前做三件事，避免"点了没反应/装成别的包"：
     * 1. 校验包名与本机一致；
     * 2. 校验 versionCode 比当前大；
     * 3. 校验签名与本机一致（不一致系统会拒绝覆盖，提前说清楚）。
     */
    private fun installApk(path: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            throw IllegalStateException("请先允许本应用安装未知应用")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val archive = packageManager.getPackageArchiveInfo(path, flags)
            ?: throw IllegalStateException("安装包解析失败，文件可能损坏")
        val current = packageManager.getPackageInfo(packageName, flags)
        if (archive.packageName != packageName) {
            throw IllegalStateException("安装包包名与本机不一致")
        }
        val archiveCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            archive.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            archive.versionCode.toLong()
        }
        val currentCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            current.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            current.versionCode.toLong()
        }
        if (archiveCode <= currentCode) {
            throw IllegalStateException("这个安装包不比当前版本新（$archiveCode ≤ $currentCode）")
        }
        if (signaturesOf(archive) != signaturesOf(current)) {
            throw IllegalStateException("安装包签名与本机不一致，不能覆盖安装；请先导出备份再卸载重装")
        }
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            File(path),
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }

    private fun signaturesOf(info: PackageInfo): Set<String> {
        val out = mutableSetOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.forEach { out.add(it.toCharsString()) }
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.forEach { out.add(it.toCharsString()) }
        }
        return out
    }

    private fun openUnknownSourcesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
            )
        } else {
            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
        }
    }

    /** 重启应用：清掉当前任务，用同一个入口重新拉起。 */
    private fun restartApp() {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: throw IllegalStateException("拿不到启动 Intent")
        intent.addFlags(
            Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK,
        )
        startActivity(intent)
        finishAffinity()
    }

    companion object {
        private const val MEDIA_CHANNEL = "com.shuaqi.shuaqi/media"
    }
}
