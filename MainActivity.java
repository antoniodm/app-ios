package it.guardroom24.notification;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            createAlarmChannel(nm);
            createDefaultChannel(nm);
        }
    }

    @Override
    public void onBackPressed() {
        WebView webView = getBridge().getWebView();
        if (webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    private void createAlarmChannel(NotificationManager nm) {
        if (nm.getNotificationChannel("alarm_channel") != null) return;

        Uri soundUri;
        int rawId = getResources().getIdentifier("alarm", "raw", getPackageName());
        if (rawId != 0) {
            soundUri = Uri.parse("android.resource://" + getPackageName() + "/" + rawId);
        } else {
            soundUri = android.provider.Settings.System.DEFAULT_ALARM_ALERT_URI;
        }

        AudioAttributes audioAttr = new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build();

        NotificationChannel channel = new NotificationChannel(
            "alarm_channel", "Allarme", NotificationManager.IMPORTANCE_HIGH
        );
        channel.setDescription("Notifiche allarme urgenti");
        channel.enableVibration(true);
        channel.setVibrationPattern(new long[]{0, 500, 200, 500, 200, 500});
        channel.setSound(soundUri, audioAttr);
        channel.setBypassDnd(true);
        nm.createNotificationChannel(channel);
    }

    private void createDefaultChannel(NotificationManager nm) {
        if (nm.getNotificationChannel("default_channel") != null) return;

        NotificationChannel channel = new NotificationChannel(
            "default_channel", "Notifiche", NotificationManager.IMPORTANCE_DEFAULT
        );
        channel.setDescription("Notifiche operative");
        nm.createNotificationChannel(channel);
    }
}
