package com.shuaqi.shuaqi

import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
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
