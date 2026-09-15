import serial, time
ser = serial.Serial('COM10', 19200, timeout=1)  # ajustar puerto
ser.write(bytes([0b100100, 2, 1]))  # OP_ADD, a=5, b=3
time.sleep(0.1)
print(ser.read(1))  # debería ser 8