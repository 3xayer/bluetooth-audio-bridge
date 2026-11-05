package local.btbridge.helper;

import android.app.Activity;
import android.bluetooth.BluetoothA2dp;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Handler;
import android.os.Parcelable;
import android.util.Log;

import java.lang.reflect.Method;

/**
 * Headless helper, driven over ADB:
 *   am start -n local.btbridge.helper/.MainActivity --es addr <MAC_BT_ADDRESS> --es cmd bond|info|a2dp
 * Everything is logged under the logcat tag "BTBridge".
 */
public class MainActivity extends Activity implements Runnable {
    static final String TAG = "BTBridge";
    BluetoothAdapter adapter;
    BluetoothDevice dev;
    final Handler handler = new Handler();

    final BroadcastReceiver rx = new Rx(this);

    static final class Rx extends BroadcastReceiver {
        final MainActivity act;
        Rx(MainActivity a) { act = a; }
        @Override public void onReceive(Context c, Intent i) {
            BluetoothDevice dev = act.dev;
            BluetoothDevice d = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
            if (d == null || dev == null || !d.getAddress().equalsIgnoreCase(dev.getAddress())) return;
            String a = i.getAction();
            if (BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(a)) {
                Log.i(TAG, "BOND_STATE " + bond(i.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1))
                        + " -> " + bond(i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1))
                        + " reason=" + i.getIntExtra("android.bluetooth.device.extra.REASON", -1));
            } else if (BluetoothDevice.ACTION_UUID.equals(a)) {
                Parcelable[] u = i.getParcelableArrayExtra(BluetoothDevice.EXTRA_UUID);
                Log.i(TAG, "UUIDs from SDP: " + join(u));
            } else if (BluetoothDevice.ACTION_ACL_CONNECTED.equals(a)) {
                Log.i(TAG, "ACL connected");
            } else if (BluetoothDevice.ACTION_ACL_DISCONNECTED.equals(a)) {
                Log.i(TAG, "ACL disconnected");
            } else if (BluetoothDevice.ACTION_PAIRING_REQUEST.equals(a)) {
                Log.i(TAG, "PAIRING_REQUEST variant=" + i.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1)
                        + " key=" + i.getIntExtra(BluetoothDevice.EXTRA_PAIRING_KEY, -1));
            } else if (BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED.equals(a)) {
                Log.i(TAG, "A2DP state -> " + i.getIntExtra(BluetoothProfile.EXTRA_STATE, -1));
            } else if (BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED.equals(a)) {
                Log.i(TAG, "A2DP playing -> " + i.getIntExtra(BluetoothProfile.EXTRA_STATE, -1));
            }
        }
    }

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        String addr = getIntent().getStringExtra("addr");
        String cmd = getIntent().getStringExtra("cmd");
        int stay = getIntent().getIntExtra("seconds", 60);
        adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || addr == null) { Log.e(TAG, "no adapter or addr"); finish(); return; }
        dev = adapter.getRemoteDevice(addr.toUpperCase());

        IntentFilter f = new IntentFilter();
        f.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        f.addAction(BluetoothDevice.ACTION_UUID);
        f.addAction(BluetoothDevice.ACTION_ACL_CONNECTED);
        f.addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED);
        f.addAction(BluetoothDevice.ACTION_PAIRING_REQUEST);
        f.addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED);
        f.addAction(BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED);
        registerReceiver(rx, f);

        Log.i(TAG, "cmd=" + cmd + " device=" + dev.getAddress() + " name=" + dev.getName()
                + " bond=" + bond(dev.getBondState()) + " class=" + dev.getBluetoothClass()
                + " uuids=" + join(dev.getUuids()));

        try {
            if ("bond".equals(cmd)) {
                boolean ok;
                try {
                    Method m = BluetoothDevice.class.getMethod("createBond", int.class);
                    ok = (Boolean) m.invoke(dev, 1 /* TRANSPORT_BREDR */);
                    Log.i(TAG, "createBond(BREDR) -> " + ok);
                } catch (NoSuchMethodException e) {
                    ok = dev.createBond();
                    Log.i(TAG, "createBond() -> " + ok);
                }
            } else if ("info".equals(cmd)) {
                Log.i(TAG, "fetchUuidsWithSdp -> " + dev.fetchUuidsWithSdp());
            } else if ("a2dp".equals(cmd)) {
                a2dpConnect();
            } else if ("unbond".equals(cmd)) {
                Method m = BluetoothDevice.class.getMethod("removeBond");
                Log.i(TAG, "removeBond -> " + m.invoke(dev));
            }
        } catch (Throwable t) {
            Log.e(TAG, "cmd failed: " + t, t);
        }

        handler.postDelayed(this, stay * 1000L);
    }

    @Override public void run() {
        Log.i(TAG, "done; bond=" + bond(dev.getBondState()) + " uuids=" + join(dev.getUuids()));
        finish();
    }

    void a2dpConnect() {
        adapter.getProfileProxy(this, new A2dpListener(dev), BluetoothProfile.A2DP);
    }

    static final class A2dpListener implements BluetoothProfile.ServiceListener {
        final BluetoothDevice dev;
        A2dpListener(BluetoothDevice d) { dev = d; }
            @Override public void onServiceConnected(int p, BluetoothProfile proxy) {
                BluetoothA2dp a2dp = (BluetoothA2dp) proxy;
                Log.i(TAG, "A2DP proxy; current state=" + a2dp.getConnectionState(dev)
                        + " connected=" + a2dp.getConnectedDevices());
                for (String name : new String[]{"setConnectionPolicy", "setPriority"}) {
                    try {
                        Method m = BluetoothA2dp.class.getMethod(name, BluetoothDevice.class, int.class);
                        Log.i(TAG, name + "(100) -> " + m.invoke(a2dp, dev, 100));
                        break;
                    } catch (Throwable t) { Log.w(TAG, name + " failed: " + rootCause(t)); }
                }
                try {
                    Method m = BluetoothA2dp.class.getMethod("connect", BluetoothDevice.class);
                    Log.i(TAG, "A2DP connect -> " + m.invoke(a2dp, dev));
                } catch (Throwable t) { Log.w(TAG, "A2DP connect failed: " + rootCause(t)); }
            }
            @Override public void onServiceDisconnected(int p) {}
    }

    @Override protected void onDestroy() {
        try { unregisterReceiver(rx); } catch (Throwable ignored) {}
        super.onDestroy();
    }

    static String rootCause(Throwable t) { while (t.getCause() != null) t = t.getCause(); return t.toString(); }
    static String bond(int s) {
        switch (s) { case 10: return "NONE"; case 11: return "BONDING"; case 12: return "BONDED"; default: return "" + s; }
    }
    static String join(Object[] a) {
        if (a == null) return "null";
        StringBuilder sb = new StringBuilder("[");
        for (Object o : a) sb.append(o).append(' ');
        return sb.append(']').toString();
    }
}
