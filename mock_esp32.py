import socket
import time
import numpy as np

# UDP Socket Setup
UDP_IP = "255.255.255.255"
UDP_PORT = 4210
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

# Demographic Baseline Parameters
base_bpm = 70.0  # Teen demographic baseline
current_bpm = base_bpm
spo2 = 98.0

# Waveform Parameters
sample_rate = 100  # 100 Hz
t = 0.0

def generate_ppg_sample(t, bpm):
    # Convert BPM to frequency (Hz)
    f = bpm / 60.0
    phase = 2 * np.pi * f * t
    
    # Systolic peak (primary wave)
    systolic = np.sin(phase)
    # Diastolic peak / dicrotic notch (secondary smaller wave)
    diastolic = 0.4 * np.sin(2 * phase - (np.pi / 4))
    
    return systolic + diastolic

print("Starting Synthetic Pulse Broadcaster...")

while True:
    # 1. Macro-Level: Apply Gaussian random walk to BPM for organic variance
    current_bpm += np.random.normal(0, 0.5) 
    # Clamp to realistic bounds for resting
    current_bpm = np.clip(current_bpm, 60, 100)
    
    # SpO2 natural variance
    spo2 += np.random.normal(0, 0.1)
    spo2 = np.clip(spo2, 95.0, 100.0)

    # 2. Micro-Level: Generate raw PPG waveform sample
    raw_ppg = generate_ppg_sample(t, current_bpm)
    
    # Format payload exactly like the ESP32 C++ firmware
    payload = f"{current_bpm:.1f},{spo2:.1f},{raw_ppg:.3f}".encode('utf-8')
    
    # Broadcast to Dart UDP Listener
    sock.sendto(payload, (UDP_IP, UDP_PORT))
    
    t += 1.0 / sample_rate
    time.sleep(1.0 / sample_rate) # Sleep to match 100Hz output