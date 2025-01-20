param($address="Any", $port=2020)

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

# $MqttClient = [uPLibrary.Networking.M2Mqtt.MqttClient]("192.168.1.20")
# $openHABUri = "http://192.168.1.50:8080/rest/items/AISReceived"
$openHABUri = $null
$homeAssistantUri = "http://192.168.1.40:8123/api/states/sensor.AISReceived"
$homeAssistantheaders = @{
    "Authorization" = ""
    "Content-Type" = "application/json"
}

$AISHubUsername = "AIS Hub Username"
$stationLatitude = 0
$stationLongitude = 0

if (Test-Path vesselCache.ps1xml)
{
	$vesselCache = Import-Clixml -Path vesselCache.ps1xml
	if ($vesselCache.count -eq 0)
	{
		$vesselCache = @{}		
	}
	else
	{
		Write-Host "Loaded $($vesselCache.count) vessels from cache"
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

Write-Host "Waiting for connections on port $($port)"
Write-Host "Press ESC to stop"
Write-Host

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
		$newVessel = $false
		$vesselMaxDistance = $false
		$vesselLastSeen = $null
		$vesselLastSeenDiff = 0
		$content = $udpclient.Receive([ref]$endpoint)
		$clientIpAddress = $endpoint.Address.ToString()
        $data = [Text.Encoding]::ASCII.GetString($content)
		$aisData = $data.Split('\')[2].trim()
		$aisSentenceCount = $aisData.Split(',')[1]

		Write-Host 

		Write-Host "Source: $($clientIpAddress)"
		if($aisSentenceCount -ne 1)
		{
			$aisData = ""
			$count = 0
			foreach($aisSentence in $data.Split('\'))
			{
				if ($aisSentence.StartsWith("!AIVDM")){
					if ($count -ne 0){$aisData += "\n"}					
					$aisData += $aisSentence.trim()
					$count++					
				}
			}
		}

		if($aisSentenceCount -gt 1)
		{
			$timeStamp = (Get-Date -UnixTimeSeconds $data.Split(',')[1].Substring(2)).ToString("yyyy-MM-ddTHH:mm:ss")
			
		}
		else
		{
			$timeStamp = (Get-Date -UnixTimeSeconds $data.Split(',')[0].Substring(3)).ToString("yyyy-MM-ddTHH:mm:ss")
		}

		# Decode AIS data
		# Using Thomas Borg Salling live API to use; best to host your own Docker container after testing
		# See http://ais.tbsalling.dk/

		$uri = 'http://ais.tbsalling.dk/decode'
		# $uri = 'http://127.0.0.1:8182/decode'
		
		$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
		$headers.Add("Content-Type", "application/json")

		# Normal approach would be to convert an object to json but due to the \n required in multi-sentence messages, build as string instead

		# Format the body for public or private decode API
		if ($uri -eq 'http://ais.tbsalling.dk/decode')
		{
			$body = '{"nmea":"' + $aisData + '"}'		
		}
		else
		{
			$body = '["' + $aisData + '"]'
		}
		$response = Invoke-RestMethod $uri -Method 'POST' -Body $body -Headers $headers
		$messageType = $response.messageType
		$mmsi = $response.sourceMmsi.mmsi

		# If message is from Kokah, use Kokah lat-lon to calc distance to vessel, else use home lat-lon

		if ($clientIpAddress -like '*192.168.2.*'){
	    Write-Host "Sent from Kokah"	
		}

		if($messageType.contains("PositionReport"))
		{
			$sog = $response.speedOverGround
			$course = $response.courseOverGround
			$navigationStatus = $response.navigationStatus
			$m = MetresDistanceBetweenTwoGPSCoordinates $stationLatitude $stationLongitude $response.latitude $response.longitude
			$nm = [math]::Round($m/1852,2)
			$shipType = $null
		}
		else
		{
			$sog = $null
			$course = $null
			$navigationStatus = $null
			$nm = $null
		}

		# ShipAndVoyageRelatedData only
		$shipName = $response.shipName
		$shipType = $response.shipType

		# Check for vessel name in cache (ASIHub API rate limit is 60 seconds)
		if ($vesselCache.ContainsKey($mmsi))
		{
			Write-Host "$($mmsi) in cache: $($vesselCache[$mmsi].name)"

			$vesselLastSeen = $vesselCache[$mmsi].timeStamp
			$vesselLastSeenDiff = ([DateTimeOffset](Get-Date)).ToUnixTimeSeconds() - $vesselLastSeen
			Write-Host "Last seen $([timespan]::fromseconds($($vesselLastSeenDiff))) ago from IP $($vesselCache[$mmsi].sourceIpAddress)"
			# Update cache timestamp, sourceIpAddress, maxNm and shipType
			$vesselCache[$mmsi].timeStamp = ([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()
			if($vesselCache[$mmsi].sourceIpAddress)
			{
				$vesselCache[$mmsi].sourceIpAddress = $clientIpAddress
			}
			else
			{
				$vesselCache[$mmsi] | Add-Member -NotePropertyName sourceIpAddress -NotePropertyValue $clientIpAddress
			}
			if ($vesselCache[$mmsi].maxNm -lt $nm)
			{
				$vesselCache[$mmsi].maxNm = $nm
				$vesselCache[$mmsi].maxNmLat = $response.latitude
				$vesselCache[$mmsi].maxNmLon = $response.longitude
				$vesselMaxDistance = $true
			}
			if ($null -eq $vesselCache[$mmsi].shipType)
			{
				$vesselCache[$mmsi].shipType = $shipType
			}
			$vessel = $vesselCache[$mmsi].name
		}
		else
		{
			if($shipName)
			{
				$vessel = $shipName
			}
			elseif (([String]$mmsi).StartsWith("99"))
			{
				$vessel = "NavAid_$($mmsi)"
			}
			else
			{
				# Get vessel name from AISHub API
				$uri = "https://data.aishub.net/ws.php?username=$($AISHubUsername)&format=1&output=json&compress=0&mmsi=$($mmsi)"
				$json = Invoke-RestMethod -Uri $uri -Method 'GET' -SkipCertificateCheck

				if ($json[1].count -ne 0)
				{
					$vessel = "$($json[1][0].name)"	
				}
			}

			if ($vessel)
			{
					# Add to cache
					Write-Host "New vessel with MMSI $($mmsi)"

					$cacheVessel = New-Object PSCustomObject -Property @{
						name = $vessel
						sog = $sog
						course = $course
						nm = $nm
						maxNm = $nm
						shipType = $shipType
						sourceIpAddress = $clientIpAddress
						timeStamp = ([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()
					}
					$vesselCache[$mmsi] = $cacheVessel	
			}			
			else
			{
				# Use MMSI if no vessel name
				$vessel = "$($mmsi)"			
			}
			$newVessel = $true
		}

		Write-Host "$($timeStamp) $($messageType)"

		if($messageType.contains("PositionReport"))
		{
			if ($vesselCache[$mmsi].shipType)
			{
				$shipType = ($vesselCache[$mmsi].shipType)				
			}

			Write-Host "$($vessel) $($shipType) $($course) deg, $($sog)kn ($($nm) nm) $($navigationStatus)"
		}
		else
		{
			Write-Host "$($vessel) $($shipType)"
		}

		Write-Host "$($aisData)"

		# Get last hour ship count
		$thresholdSeconds = 3600
		$offset = (([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()) - $thresholdSeconds
		$inPeriod = $vesselCache.values | ForEach-Object {if ($_.sourceIpAddress -like "*$($clientIpAddress.Substring(0,10))*" -and $_.timeStamp -gt $offset) {$_.name}}
		$vesselsInLastHour = $inPeriod.Count
		Write-Host "Vessels in last hour for *$($clientIpAddress.Substring(0,10))*: $($vesselsInLastHour)"

		# Send MQTT

		# Send to OpenHAB
		if ($openHABUri)
		{		
			$bodyParams = @{
				"messageType" = $messageType
				"vessel" = $vessel
				"course" = $course
				"sog" = $sog
				"nm" = $nm
				"navigationStatus" = $navigationStatus
				"shipType" = $shipType
				"newVessel" = $newVessel
				"vesselMaxDistance" = $vesselMaxDistance
				"vesselLastSeen" = $vesselLastSeen
				"vesselLastSeenDiff" = $vesselLastSeenDiff
				"sourceIpAddress" = $clientIpAddress
				"vesselsInLastHour" = $vesselsInLastHour
				}
			$body = $bodyParams | ConvertTo-Json -Compress

			try
			{
				Invoke-WebRequest $openHABUri -Body $body -Method 'Post' -ContentType 'text/plain' | Out-Null				
			}
			catch
			{
				Write-Host "Failed to post to OpenHAB"
			}
		}

		# Send to Home Assistant
		if ($homeAssistantUri)
		{
			$bodyParams = @{
				"state" = "online"
				"attributes" = @{
					"messageType" = $messageType
					"vessel" = $vessel
					"course" = $course
					"sog" = $sog
					"nm" = $nm
					"navigationStatus" = $navigationStatus
					"shipType" = $shipType
					"newVessel" = $newVessel
					"vesselMaxDistance" = $vesselMaxDistance
					"vesselLastSeen" = $vesselLastSeen
					"vesselLastSeenDiff" = $vesselLastSeenDiff
					"sourceIpAddress" = $clientIpAddress
					"vesselsInLastHour" = $vesselsInLastHour
				}
				}
			$body = $bodyParams | ConvertTo-Json

			try
			{
				Invoke-RestMethod -uri $homeAssistantUri -Headers $homeAssistantheaders -Body $body -Method 'POST' | Out-Null				
			}
			catch
			{
				Write-Host "Failed to post to Home Assistant"
			}
		}

		# Serialize vesselCache
		$vesselCache | Export-Clixml -Path vesselCache.ps1xml			
		
		Write-Host
	}
}
$udpclient.Close()