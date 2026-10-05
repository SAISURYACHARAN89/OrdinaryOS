package com.atmosphere.ordi_audio

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Finding and pairing a Bluetooth headset — the Audios are one — from inside
 * the app. Android allows this; iOS does not, and there the first pairing
 * happens in Settings.
 *
 * A headset is not a low-energy device: it is found by classic discovery and
 * joined by bonding, after which the phone itself connects its audio now and
 * every time it is switched on. Nothing here holds that connection.
 * Touch only from the main thread.
 */
@SuppressLint("MissingPermission")
internal class ClassicBluetooth(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val found = LinkedHashMap<String, Map<String, Any>>()
    private var receiver: BroadcastReceiver? = null

    /** The bond being made, and who is waiting to hear how it went. */
    private var pairing: Pair<String, (Boolean) -> Unit>? = null
    private var pairTimeout: Runnable? = null

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private fun allowed(permission: String): Boolean =
        Build.VERSION.SDK_INT < 31 ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Starts looking for headsets nearby; [found] fills in over ~12 seconds. */
    fun search(): Boolean {
        val adapter = adapter ?: return false
        if (!allowed(Manifest.permission.BLUETOOTH_SCAN)) return false
        return try {
            if (!adapter.isEnabled) return false
            listen()
            found.clear()
            if (adapter.isDiscovering) adapter.cancelDiscovery()
            adapter.startDiscovery()
        } catch (error: Exception) {
            false
        }
    }

    /** Named devices seen since the last [search]: name, address, rssi. */
    fun found(): List<Map<String, Any>> = found.values.toList()

    /**
     * Pairs with the headset at [address] and reports whether it worked. The
     * phone may show its own "pair with…?" prompt on the way.
     */
    fun pair(address: String, done: (Boolean) -> Unit) {
        val adapter = adapter ?: return done(false)
        if (!allowed(Manifest.permission.BLUETOOTH_CONNECT)) return done(false)
        // One at a time: an earlier attempt still waiting has been abandoned.
        finishPairing(false)
        try {
            val device = adapter.getRemoteDevice(address)
            if (device.bondState == BluetoothDevice.BOND_BONDED) {
                connectAudio(device)
                return done(true)
            }
            listen()
            // Discovery and bonding share the radio; bonding fails while the
            // other is still running.
            if (allowed(Manifest.permission.BLUETOOTH_SCAN) && adapter.isDiscovering) {
                adapter.cancelDiscovery()
            }
            pairing = address to done
            val timeout = Runnable { finishPairing(false) }
            pairTimeout = timeout
            main.postDelayed(timeout, PAIR_TIMEOUT_MS)
            if (device.bondState != BluetoothDevice.BOND_BONDING && !device.createBond()) {
                finishPairing(false)
            }
        } catch (error: Exception) {
            if (pairing?.first == address) finishPairing(false) else done(false)
        }
    }

    private fun finishPairing(success: Boolean) {
        val waiting = pairing ?: return
        pairing = null
        pairTimeout?.let(main::removeCallbacks)
        pairTimeout = null
        waiting.second(success)
    }

    private fun listen() {
        if (receiver != null) return
        val created = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                @Suppress("DEPRECATION")
                val device: BluetoothDevice =
                    intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) ?: return
                when (intent.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val name = intent.getStringExtra(BluetoothDevice.EXTRA_NAME)
                            ?: try { device.name } catch (error: Exception) { null }
                        if (name.isNullOrEmpty()) return
                        val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, (-70).toShort())
                        found[device.address] = mapOf(
                            "name" to name,
                            "address" to device.address,
                            "rssi" to rssi.toInt(),
                        )
                    }

                    BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                        if (device.address != pairing?.first) return
                        val state = intent.getIntExtra(
                            BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
                        if (state == BluetoothDevice.BOND_BONDED) {
                            connectAudio(device)
                            finishPairing(true)
                        } else if (state == BluetoothDevice.BOND_NONE) {
                            // Refused on the phone, or the headset went away.
                            finishPairing(false)
                        }
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            // These come from the system, which is not "another app".
            context.registerReceiver(created, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(created, filter)
        }
        receiver = created
    }

    /**
     * A phone normally connects a headset's audio by itself once paired. On
     * the phones that wait for the headset to ask first, this asks. Android
     * has no public call for it, so the hidden one is tried and a refusal is
     * not an error: the audio connects the next time the headset is switched
     * on.
     */
    private fun connectAudio(device: BluetoothDevice) {
        for (profile in intArrayOf(BluetoothProfile.HEADSET, BluetoothProfile.A2DP)) {
            try {
                adapter?.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(which: Int, proxy: BluetoothProfile) {
                        try {
                            proxy.javaClass.getMethod("connect", BluetoothDevice::class.java)
                                .invoke(proxy, device)
                        } catch (error: Exception) {
                            // Not offered to apps on this version.
                        }
                        main.postDelayed({
                            try { adapter?.closeProfileProxy(which, proxy) } catch (error: Exception) {}
                        }, 15_000)
                    }

                    override fun onServiceDisconnected(which: Int) {}
                }, profile)
            } catch (error: Exception) {
                // No Bluetooth, or no permission.
            }
        }
    }

    fun dispose() {
        finishPairing(false)
        receiver?.let {
            try { context.unregisterReceiver(it) } catch (error: Exception) {}
        }
        receiver = null
        try {
            if (allowed(Manifest.permission.BLUETOOTH_SCAN)) adapter?.cancelDiscovery()
        } catch (error: Exception) {}
    }

    private companion object {
        /** Long enough to read and accept the phone's own pairing prompt. */
        const val PAIR_TIMEOUT_MS = 40_000L
    }
}
