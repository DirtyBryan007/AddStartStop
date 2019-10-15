
# README

# all servers will be scanned for jobs not on the dashboard .
# Servers are added to text file in format of
# run in powershell like . .\AddStartStop.ps1
# Then call the function you want by just specifying function i.e. Main
# Current use of this script reads in jobs from a text file called jobs.txt and if the job is found on sql server and 
#does not contain a step called "WRITE TO LOG START" then add a start and stop step.  
#load assemblies
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | Out-Null
#Need SmoExtended for backup
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SmoExtended") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SQLWMIManagement') | out-null
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Management.Smo.Agent.JobStep') | out-null


#Main gets servers, then each job from that server, then for the jobs that dont have a certain step
# It adds a start and a stop step
function Main(){
	#for every job in each server create a connection to sql and add the start/stop steps
    $servers = Get-Servers
    $EnabledJobs = Get-AgentJobs($servers)
	foreach($inst in $EnabledJobs.keys)
	{
		$svr = new-object ('Microsoft.SqlServer.Management.Smo.Server') $inst
        
		foreach ($jobName in $EnabledJobs[$inst])
		{
			Write-Host "Adding Job: $jobName on server $inst"
			$job = $svr.jobserver.jobs[$jobName]
            try
            {
			Start-Step($job)
			Alter-Step($job)
            Stop-Step($job)

            }
            catch
            {
                Write-Host "Create failed for job: $job"
            }
            
            
		}
		Write-Host "------------------"
		$svr.ConnectionContext.Disconnect()
	}
			
		


}
# Adds in the start step based off the job. 
function Start-Step($job){
   # $svr.ConnectionContext.LoginSecure=$true    
    
    Write-Host ($job | Format-Table | Out-String)
    #Write-Host ($job | Format-Table | Out-String)
    Write-Host "Job: $job"
	$jsStart = new-object ('Microsoft.SqlServer.Management.Smo.Agent.JobStep') ($job, 'WRITE TO LOG - START')
	$jsStart.DatabaseName = 'TOOLS'
	$jsStart.Command = "SQL STATEMENT HERE"
	$jsStart.OnSuccessAction = 'GoToNextStep'
	$jsStart.OnFailAction = 'GoToNextStep'
	$jsStart.ID = 1
	try
	{
        
		$jsStart.Create()
	}
	catch
	{
		$error[0]|format-list -force
	
	}
	
	
}

# Create a stop step. If stop step fails to create then we need to drop the start step aswell
function Stop-Step($job){
	$stepId = 0
	foreach($step in $job.JobSteps)
    {	
		$stepId += 1
    }
	#Create the stop step and set what to do on fail and success
	$jsStop = new-object ('Microsoft.SqlServer.Management.Smo.Agent.JobStep') ($job, 'WRITE TO LOG - STOP')
			$jsStop.DatabaseName = 'TOOLS'
			$jsStop.Command = "SQL STATEMENT HERE"
			$jsStop.OnSuccessAction = 'QuitWithSuccess'
			$jsStop.OnFailAction = 'QuitWithSuccess'
			# add to the end of the steps. +1 because count starts at 0 then add to log start is added so we need to add 1
			$jsStop.ID = $stepId + 1
			try
			{
				$jsStop.Create()
                Write-Host "Create Stop-Step SUCCESS"
			}
			catch
			{
				$error[0]|format-list -force
                foreach($step in $job.JobSteps)
			    {
                    if($step.Name -eq "WRITE TO LOG - START")
				    {
					    $step.drop()
                        break
				    }
                }
			}
			
}

#Change the last step to continue to next step since we dont want it to quit before the stop step. if it fails then delete start step
function Alter-Step($job)
{
	$stepId = 0
    foreach($step in $job.JobSteps)
    {	
		$stepId += 1
    }	
    $step.OnSuccessAction = 'GoToNextStep'
    
    try
	{
		$step.Alter()
        Write-Host "Alter-Step SUCCESS"
	}
	catch
	{
		$error[0]|format-list -force
        foreach($step in $job.JobSteps)
	    {
            if($step.Name -eq "WRITE TO LOG - START")
		    {
			    $step.drop()
                break
		    }
        }

	}

}
#Get a list of servers. This is a custom table I have that contains a list of all production servers on sql
function Get-Servers()
{
    $srvCmd = @((Invoke-Sqlcmd -ServerInstance "ServerName" -Database "master" -Query "SELECT [SRVR_NM]
	FROM [Master].[dbo].[SRVR_LST]
	WHERE SRVR_LF_CYCL = 'P' AND ACTV_STAT_CD = 'A'").ItemArray -join ' ' | ft -HideTableHeaders | Out-String).Trim() 
	$servers = $srvCmd.split(" ")
    return $servers
}
#Get the agent jobs and put into hash array @(Server1, [job1, job2, job3], Server2, [job1, job2])
#Currently I am only interested ina  few jobs I have stored in a text file. If you want all jobs remove the line
# $Name = Select-String -Path .\jobs.txt -Pattern $job.Name
function Get-AgentJobs($servers)
{
    $JobHash = @{}
	#Counter variable for rows
	#iterate through each server 
	foreach ($instance in $servers)
	{	   
		# Create an SMO connection to the instance
		$JobHash[$instance] = @()
		$srv = New-Object ('Microsoft.SqlServer.Management.Smo.Server') $instance
		$jobs=$srv.JobServer.Jobs
		$jobInServer = $false

		foreach ($job in $jobs)  
		{ 	
			
			# if the current job is in our txt file of job names to add to the dashboard then select the name
			$Name = Select-String -Path .\jobs.txt -Pattern $job.Name
			$inDash = Get-JobSteps($job)		
			#if the job is enabled, it is not in the dashboard, and the name was found in our txt file then add it to the list
			if($job.IsEnabled -And $inDash -eq $false -And $Name -ne $null)
			{
			    $jobname = $job.Name
			    $JobHash[$instance] += "$jobname"  
			    $jobInServer = $true
				Write-Host "Job: $jobname Server: $instance"
				
			} 
		
	   }
	   if($jobInServer -eq $false)
	   {
		$JobHash.Remove($instance)
	   }

	}
    return $JobHash
}
#Looks for a job step with a name WRITE TO LOG - START and if it already has it then dont add to the array
function Get-JobSteps($job)
{
    $inDash = $false
    foreach($step in $job.JobSteps)
			{
				if($step.Name -like "*WRITE TO LOG - START*")
				{
					$inDash = $true
				}
			}
    return $inDash
}
