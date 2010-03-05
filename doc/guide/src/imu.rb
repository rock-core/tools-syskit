require 'orocos'
include Orocos

Orocos.initialize
Orocos.run 'imu' do
  imu = TaskContext.get 'imu'
  imu.port = '/dev/ttyS1' # sets a new value for the port
  imu.configure
  imu.start

  imu_reader = imu.imu_readings.reader
  
  # Display samples that get out of the IMU
  # See base/base/imu_readings.h for the definition of base::IMUReading
  while true
    sleep 0.1
    if sample = imu_reader.read
      orientation = sample.orientation
      puts "[#{orientation.re.to_a.join(", ")}] #{orientation.im}"
    end
  end
end

