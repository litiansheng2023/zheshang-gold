import pathlib, os, re, glob

# ---------- 1) AndroidManifest：权限 + 前台服务 + 桌面小组件 ----------
mp = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = mp.read_text(encoding='utf-8')
perms = '\n    '.join([
    '<uses-permission android:name="android.permission.INTERNET"/>',
    '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>',
    '<uses-permission android:name="android.permission.VIBRATE"/>',
    '<uses-permission android:name="android.permission.WAKE_LOCK"/>',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>',
    '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>',
    '<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>',
]) + '\n    '
extra = '\n        '.join([
    '<service',
    '    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"',
    '    android:foregroundServiceType="specialUse"',
    '    android:exported="false">',
    '    <property',
    '        android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"',
    '        android:value="realtime gold price monitoring and user-defined price alerts"/>',
    '</service>',
    '<receiver',
    '    android:name=".GoldWidgetProvider"',
    '    android:label="浙商金价"',
    '    android:exported="true">',
    '    <intent-filter>',
    '        <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>',
    '    </intent-filter>',
    '    <meta-data',
    '        android:name="android.appwidget.provider"',
    '        android:resource="@xml/gold_widget_info"/>',
    '</receiver>',
])
assert '<application' in s and '</application>' in s
s = s.replace('<application', perms + '<application', 1)
s = s.replace('</application>', '    ' + extra + '\n    </application>', 1)
mp.write_text(s, encoding='utf-8')

# ---------- 2) Gradle：desugaring（本地通知插件需要）+ Java 17 ----------
kts = os.path.exists('android/app/build.gradle.kts')
gp = pathlib.Path('android/app/build.gradle.kts' if kts else 'android/app/build.gradle')
g = gp.read_text(encoding='utf-8')
g = g.replace('VERSION_11', 'VERSION_17')
if kts:
    g = g.replace('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
    g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
else:
    g = g.replace('compileOptions {', 'compileOptions {\n        coreLibraryDesugaringEnabled true', 1)
    g += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
gp.write_text(g, encoding='utf-8')

# ---------- 3) 桌面小组件：布局 / 配置 / 背景 / Kotlin ----------
res = pathlib.Path('android/app/src/main/res')
for d in ('layout', 'xml', 'drawable'):
    (res / d).mkdir(parents=True, exist_ok=True)

(res / 'drawable' / 'widget_bg.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#E61E1E1E"/>
    <corners android:radius="16dp"/>
</shape>
''', encoding='utf-8')

(res / 'xml' / 'gold_widget_info.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="180dp"
    android:minHeight="90dp"
    android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/gold_widget"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen"/>
''', encoding='utf-8')

(res / 'layout' / 'gold_widget.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:gravity="center_vertical"
    android:padding="12dp"
    android:background="@drawable/widget_bg">

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:gravity="center_vertical">
        <TextView
            android:layout_width="52dp"
            android:layout_height="wrap_content"
            android:text="浙商"
            android:textColor="#BBBBBB"
            android:textSize="13sp"/>
        <TextView
            android:id="@+id/zs_price"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:maxLines="1"
            android:text="--"
            android:textColor="#FFFFFF"
            android:textSize="22sp"
            android:textStyle="bold"/>
        <TextView
            android:id="@+id/zs_change"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:layout_marginLeft="8dp"
            android:maxLines="1"
            android:text=""
            android:textColor="#FFFFFF"
            android:textSize="12sp"/>
    </LinearLayout>

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="4dp"
        android:orientation="horizontal"
        android:gravity="center_vertical">
        <TextView
            android:layout_width="52dp"
            android:layout_height="wrap_content"
            android:text="伦敦金"
            android:textColor="#BBBBBB"
            android:textSize="13sp"/>
        <TextView
            android:id="@+id/ld_price"
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:maxLines="1"
            android:text="--"
            android:textColor="#FFFFFF"
            android:textSize="22sp"
            android:textStyle="bold"/>
        <TextView
            android:id="@+id/ld_change"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:layout_marginLeft="8dp"
            android:maxLines="1"
            android:text=""
            android:textColor="#FFFFFF"
            android:textSize="12sp"/>
    </LinearLayout>

    <TextView
        android:id="@+id/updated"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginTop="4dp"
        android:text=""
        android:textColor="#888888"
        android:textSize="10sp"/>
</LinearLayout>
''', encoding='utf-8')

# Kotlin 提供者：放到 MainActivity 所在的包里
ma = glob.glob('android/app/src/main/kotlin/**/MainActivity.kt', recursive=True) \
   + glob.glob('android/app/src/main/java/**/MainActivity.*', recursive=True)
assert ma, 'MainActivity not found'
pkg = re.search(r'^package\s+([\w.]+)', pathlib.Path(ma[0]).read_text(encoding='utf-8'), re.M).group(1)
kotlin = '''package __PKG__

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

class GoldWidgetProvider : HomeWidgetProvider() {

    private fun colorOf(flag: String?): Int = when (flag) {
        "up" -> Color.parseColor("#FF5252")
        "down" -> Color.parseColor("#4CAF50")
        else -> Color.WHITE
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.gold_widget)
            views.setTextViewText(R.id.zs_price, widgetData.getString("zs_price", "--"))
            views.setTextViewText(R.id.zs_change, widgetData.getString("zs_change", ""))
            views.setTextViewText(R.id.ld_price, widgetData.getString("ld_price", "--"))
            views.setTextViewText(R.id.ld_change, widgetData.getString("ld_change", ""))
            views.setTextViewText(R.id.updated, widgetData.getString("updated", "打开 App 后开始更新"))

            val zsColor = colorOf(widgetData.getString("zs_flag", ""))
            val ldColor = colorOf(widgetData.getString("ld_flag", ""))
            views.setTextColor(R.id.zs_price, zsColor)
            views.setTextColor(R.id.zs_change, zsColor)
            views.setTextColor(R.id.ld_price, ldColor)
            views.setTextColor(R.id.ld_change, ldColor)

            // 点击小组件打开 App
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launch != null) {
                val pi = PendingIntent.getActivity(
                    context, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_root, pi)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
'''.replace('__PKG__', pkg)
(pathlib.Path(ma[0]).parent / 'GoldWidgetProvider.kt').write_text(kotlin, encoding='utf-8')

print('patched:', mp, gp, 'widget package', pkg)
