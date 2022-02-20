param($address="Any", $port=2020)

# $MqttClient = [uPLibrary.Networking.M2Mqtt.MqttClient]("127.0.0.1")
$openHABUri = "http://192.168.1.50:8080/rest/items/AISReceived"
$AISHubUsername = "your AISHub username"
$stationLatitude = 0.0
$stationLongitude = 0.0

Function MetresDistanceBetweenTwoGPSCoordinates($latitude1, $longitude1, $latitude2, $longitude2)  
{
  # https://stackoverflow.com/a/13069278
  $Rad = ([math]::PI / 180);  

  $earthsRadius = 6378.1370 # Earth's Radius in KM  
  $dLat = ($latitude2 - $latitude1) * $Rad  
  $dLon = ($longitude2 - $longitude1) * $Rad  
  $latitude1 = $latitude1 * $Rad  
  $latitude2 = $latitude2 * $Rad  

  $a = [math]::Sin($dLat / 2) * [math]::Sin($dLat / 2) + [math]::Sin($dLon / 2) * [math]::Sin($dLon / 2) * [math]::Cos($latitude1) * [math]::Cos($latitude2)  
  $c = 2 * [math]::ATan2([math]::Sqrt($a), [math]::Sqrt(1-$a))  

  $distance = [math]::Round($earthsRadius * $c * 1000, 0) #Multiple by 1000 to get metres  

  Return $distance  
}

if (Test-Path vesselCache.ps1xml)
{
	$vesselCache = Import-Clixml -Path vesselCache.ps1xml
	if ($vesselCache.count -eq 0)
	{
		$vesselCache = @{}		
	}
}
else
{
	$vesselCache = @{}	
}

try{
	$endpoint = new-object System.Net.IPEndPoint( [IPAddress]::$address, $port )
	$udpclient = new-object System.Net.Sockets.UdpClient $port
}
catch{
	throw $_
	exit -1
}

Write-Host "Waiting for connections on port $($port)" -fore yellow
Write-Host "Press ESC to stop"
Write-Host ""
while($true)
{
	if($host.ui.RawUi.KeyAvailable)
	{
		$key = $host.ui.RawUI.ReadKey("NoEcho,IncludeKeyUp,IncludeKeyDown")
		if($key.VirtualKeyCode -eq 27)
		{break}
	}

	if($udpclient.Available)
	{
		$vessel = $null

		$content = $udpclient.Receive( [ref]$endpoint )
		# Write-Host "$($endpoint.Address.IPAddressToString):$($endpoint.Port) $(([Text.Encoding]::ASCII.GetString($content)).trim())"
        $data = [Text.Encoding]::ASCII.GetString($content)

		$timeStamp = (Get-Date -UnixTimeSeconds $data.Split(',')[0].Substring(3)).ToString("yyyy-MM-ddTHH:mm:ss")
		$aisData = $data.Split('\')[2].trim()

		$aisSentenceCount = $aisData.Split(',')[1]
		
		if($aisSentenceCount -ne 1)
		{
    		$sentenceNumber = $aisData.Split(',')[2]
			Write-Host "$($aisSentenceCount) sentences present"
			Write-Host "Sentence $($sentenceNumber) of $($aisSentenceCount)"
		}
		
		# Decode AIS data
		$uri = 'http://ais.tbsalling.dk/decode'
		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Content-Type", "application/json")
		$bodyParams = @(@{"nmea" = $aisData})
		$body = $bodyParams | ConvertTo-Json -Depth 2 -Compress
		$response = Invoke-RestMethod $uri -Method 'POST' -Body $body -Headers $headers # -SkipCertificateCheck
		$mmsi = $response.sourceMmsi.mmsi
		$sog = $response.speedOverGround
		$course = $response.courseOverGround
		$navigationStatus = $response.navigationStatus
		$m = MetresDistanceBetweenTwoGPSCoordinates $stationLatitude $stationLongitude $response.latitude $response.longitude
		$nm = [math]::Round($m/1852,2)

		# Get vessel name from cache (ASIHub API rate limit 60 seconds)
		if ($vesselCache.ContainsKey($mmsi))
		{
			$vessel = $vesselCache[$mmsi]
		}
		else
		{
			# Get vessel name from AISHub API
			$uri = "https://data.aishub.net/ws.php?username=$($AISHubUsername)&format=1&output=json&compress=0&mmsi=$($mmsi)"
			$json = Invoke-RestMethod -Uri $uri -Method 'GET' -SkipCertificateCheck

			if ($json[1].count -ne 0)
			{
				$vessel = "$($json[1][0].name)"	
				# Add to cache
				$vesselCache[$mmsi] = $vessel	
			}
			else
			{
				# Use MMSI if no vessel name
				$vessel = "$($mmsi)"			
			}
		}
		
		Write-Host "$($timeStamp) $($vessel) $($course) deg, $($sog)kn ($($nm) nm) $($navigationStatus)"
		Write-Host "$($aisData)"

        # Send MQTT

		# Send to OpenHAB
		if ($openHABUri)
		{
			if ($navigationStatus -eq 'AtAnchor')
			{
				$ohData = "$($vessel) at anchor $($nm)"
			}
			else
			{
				$ohData = "$($vessel) $($course) deg, $($sog)kn ($($nm) nm)"
			}
			Invoke-WebRequest $openHABUri -Body $ohData -Method 'Post' -ContentType 'text/plain' | Out-Null
		}

		# Serialize vesselCache
		$vesselCache | Export-Clixml -Path vesselCache.ps1xml
	}
}
$udpclient.Close()