require "csv"
require "optparse"
require "ostruct"
require "etc"
require "fileutils"

class SdcWebSiteMaker
	STUDENT_RECORD_NUM_FIELDS = 5
	PROJECT_RECORD_NUM_FIELDS = 6
	SEMESTERS = %w(Spring SummerI SummerII Fall)

	STUDENTS_DIRECTORY = "students"
	PROJECTS_DIRECTORY = "projects"

	Student = Struct.new("Student", :year, :semester, :className, :userName, :name)
	Project = Struct.new("Project", :year, :semester, :className, :name, :directoryName, :groupName, :students)

	def initialize(csvFilename, directory, test=true)
		@csvFilename, @directory, @test = csvFilename, directory, test
		@students, @projects = {}, {}
		@existingUsers = []
		Etc.passwd {|e| @existingUsers << e.name}

		readSdcCsvFile
	end

	def make
		correctSdcGroups
		correctSdcUsers
		makeDirectories
		createIndexHtml
	end

	private

	# ensure year is four digits
	def isValidYear?(year)
		year =~ /^\d{4}$/
	end

	# From the useradd man page:
	#  Usernames must begin with a lower case letter or an underscore,
	#  and only lower case letters, underscores, dashes, and dollar signs may follow.
	#  In regular expression terms: [a-z_][a-z0-9_-]*[$]
	# so, let's ensure userName has only legitimate unix userName characters minus a trailing $
	def isValidUserName?(userName)
		userName =~ /^[a-z_][a-z0-9_-]*$/
	end

	# ensure semester is in our enum
	def isValidSemester?(semester)
		SEMESTERS.include? semester
	end

	def isValidDirectoryName?(directoryName)
		directoryName =~ /^[a-zA-Z0-9_]+$/
	end

	def readSdcCsvFile
		records = CSV.read(@csvFilename)
		records -= [[nil]]

		# read student records
		studentRecords = records.select {|e| e[0] =~ /student/i}
		records -= studentRecords

		studentRecords.each do |record|
			record.delete_at(0)

			unless record.size == STUDENT_RECORD_NUM_FIELDS
				raise \
					"student record has an invalid number of fields " +
						"(expected #{STUDENT_RECORD_NUM_FIELDS}, but got #{record.size}) " +
					record.inspect
			end

			year, semester, className, userName, name = record

			raise "invalid username '#{userName}'" unless isValidUserName? userName
			raise "invalid year '#{year}'" unless isValidYear? year
			raise "invalid semester '#{semester}'" unless isValidSemester? semester

			# ensure it isn't a duplicate entry
			if @students.has_key? userName
				raise "student with username '#{userName}' already exists" 
			end

			@students[userName] = Student.new(year.to_i, semester, className, userName, name)
		end

		# read project records
		projectRecords = records.select {|e| e[0] =~ /project/i}
		records -= projectRecords

		projectRecords.each do |record|
			record.delete_at(0)

			unless record.size == PROJECT_RECORD_NUM_FIELDS
				raise \
					"project record has an invalid number of fields (#{record.size} " +
						"instead of #{PROJECT_RECORD_NUM_FIELDS})\n" +
					record.inspect
			end

			year, semester, className, directoryName, userNames, name = record

			raise "invalid year '#{year}'" unless isValidYear? year
			raise "invalid semester '#{semester}'" unless isValidSemester? semester
			raise "invalid directoryName '#{directoryName}'" unless isValidDirectoryName? directoryName

			students =
				userNames.split(',').map {|userName|
					raise "student with userName '#{userName}' does not exist" unless @students.has_key?(userName)
					@students[userName]
				}

			@projects[directoryName] =
			   	Project.new(
					year.to_i,
				   	semester,
				   	className,
				   	name,
				   	directoryName,
				   	makeSdcGroupName(directoryName),
				   	students
				)
		end

		# there shouldn't be any more records
		raise "couldn't understand the following records:\n#{records.inspect}" if records.size > 0

		# years and semesters sorted descending
		# trying to fix it so newest stuff appears at the top
		# years are compared numerically. semesters are compared by their SEMESTERS index.
		@years_and_semesters = (@students.values + @projects.values).map {|e|
			[e.year, e.semester]
		}.uniq.sort {|a,b|
			r = b[0].to_i <=> a[0].to_i
			r == 0 ?
				SEMESTERS.index(b[1]) <=> SEMESTERS.index(a[1]) :
				r
		}
	end

	# ----------------------------------------------------------------------------------------------------

	def correctSdcGroups
		# scrape sdc_* groups from group db
		existingSdcGroups = []
		Etc.group {|e| existingSdcGroups << e.name if e.name =~ /^sdc_/}

		projectGroups = @projects.values.collect {|project| project.groupName}
		intersection = existingSdcGroups & projectGroups

		groupsToAdd = projectGroups - intersection
		groupsToDel = existingSdcGroups - intersection

#		groupsToAdd.each do |group|
#			cmd = "groupadd #{group}"
#			@test ? puts(cmd) : `#{cmd}`
#		end
		# XXX do we really want to do this?
		groupsToDel.each do |group|
			cmd = "groupdel #{group}"
			@test ? puts(cmd) : `#{cmd}`
		end
	end

	# ----------------------------------------------------------------------------------------------------

	def groupsByMember(userNames)
		groups = {}
		Etc.group do |group|
			group.mem.each {|userName|
				if userNames.include?(userName)
					groups[userName] ||= []
					groups[userName] << group.name
				end
			}
		end
		groups
	end

	# ----------------------------------------------------------------------------------------------------

	def correctSdcUsers
		userNames = @students.keys
		groups = groupsByMember(userNames)

		userNames.each do |userName|
			projectGroupsUserShouldBeIn =
				@projects.values.select {|project|
					project.students.include? @students[userName]
				}.collect {|project|
					project.groupName
				}

			# find the sdc groups a user is already in
			sdcGroupsUserIsIn = groups[userName].to_a.select {|e| e =~ /^sdc_/}
			# find the non-sdc groups a user is in
			nonSdcGroupsUserIsIn = groups[userName].to_a - sdcGroupsUserIsIn
			# groups they should be in are project groups they should be in and non sdc groups they were in
			groupsUserShouldBeIn = projectGroupsUserShouldBeIn.to_a | nonSdcGroupsUserIsIn
			# groups to be removed from are the groups they are in minus the groups they should be in
			groupsToBeRemovedFrom = groups[userName].to_a - groupsUserShouldBeIn
			# groups to add are groups they should be in minus groups they are in
			groupsToBeAddedTo = groupsUserShouldBeIn - groups[userName].to_a

			# set their group if there are any to be added or removed
#			if groupsToBeRemovedFrom.size > 0 || groupsToBeAddedTo.size > 0
#				# XXX is this safe?
#				groupsString = groupsUserShouldBeIn.join(',')
#				cmd = "usermod -G '#{groupsString}' #{userName}"
#				@test ? puts(cmd) : `#{cmd}`
#			end
		end
	end

	# ----------------------------------------------------------------------------------------------------
	
	def makeDirectory(directory, user, group, mode)
		user, group = "root", "root" unless @existingUsers.include?(user)
		puts "making directory #{directory} user=#{user} group=#{group} mode=#{"%o" % mode}"
		if @test
			puts "mkdir #{directory}"
#			puts "chown -R #{user}:#{group} #{directory}"
			return
		end

		begin
			FileUtils.mkdir(directory, :mode => mode)
		rescue Errno::EEXIST => e
			puts "directory #{directory} already exists"
#		ensure
#			FileUtils.chown_R(user, group, directory)
		end
	end

	def makeDirectories
		makeDirectory(@directory, 'root', 'root', 0755)

		base = "#{@directory}/#{STUDENTS_DIRECTORY}"
		makeDirectory(base, 'root', 'root', 0755)

		@students.values.each do |student|
			studentDir = base + '/' + student.userName
			makeDirectory(studentDir, student.userName, student.userName, 0711)
		end

		base = "#{@directory}/#{PROJECTS_DIRECTORY}"
		makeDirectory(base, 'root', 'root', 0755)

		@projects.values.each do |project|
			projectDir = base + '/' + project.directoryName
			makeDirectory(projectDir, 'root', project.groupName, 02771)
		end
	end

	# ----------------------------------------------------------------------------------------------------

	def createIndexHtml
		students_html = ""
		projects_html = ""

		@years_and_semesters.each do |year, semester|
			# append students of year and semester to students block
			tmp = @students.values.select {|student|
				student.year == year and student.semester == semester
			}.sort_by {|student|
				student.name.split[-1]
			}

			if tmp.size > 0
				students_html += "\t\t\t<h2>#{year} #{semester}</h2>\n"
				students_html += "\t\t\t<ul>\n"
				tmp.each {|student| students_html += "\t\t\t\t<li><a href=\"/students/#{student.userName}\">#{student.name.split[-1]}, #{student.name.split[0..-2].join(" ")}</a></li>\n" }
				students_html += "\t\t\t</ul>\n"
			end

			# append projects of year and semester to projects block
			tmp = @projects.values.select {|project|
				project.year == year and project.semester == semester
			}.sort_by {|project|
				project.name
			}

			if tmp.size > 0
				projects_html += "\t\t\t<h2>#{year} #{semester}</h2>\n"
				projects_html += "\t\t\t<ul>\n"
				tmp.each {|project|
					projects_html += "\t\t\t\t<li>\n"
					projects_html += "\t\t\t\t\t<a href=\"/projects/#{project.directoryName}\">#{project.name}</a>\n"
					projects_html += "\t\t\t\t\t<ul>\n"
					project.students.sort_by {|student|
						student.name.split[-1]
					}.each {|student|
						projects_html += "\t\t\t\t\t\t<li><a href=\"/students/#{student.userName}\">#{student.name.split[-1]}, #{student.name.split[0..-2].join(" ")}</a></li>\n"
					}
					projects_html += "\t\t\t\t\t</ul>\n"
					projects_html += "\t\t\t\t</li>\n"
				}
				projects_html += "\t\t\t</ul>\n"
			end
		end

		css = <<_EOF_
a, a:visited
{
	background: inherit;
	color: blue;
}

body, h1, h2
{
	font-family: Verdana;
}

#heading
{
	margin-bottom: 1em;
}
#heading h1
{
	font-size: 1.5em;
	margin: 0;
}

#studentsList, #projectsList
{
	background: #f4f4f4;
	border: 1px solid #ccc;
	float: left;
	padding: 0 1em;
}
#studentsList ul, #projectsList ul
{
	list-style: none;
	margin-top: 0;
	padding-top: 0;
}
#studentsList li, #projectsList li
{
	white-space: nowrap;
}
#studentsList h1, #projectsList h1
{
	font-size: 1.5em;
}
#studentsList h2, #projectsList h2
{
	font-size: 1.2em;
	margin-bottom: 0;
	padding-bottom: 0;
}
#projectsList>ul>li
{
	margin-bottom: 1em;
}
#projectsList
{
	margin-left: 1em;
}
_EOF_

		html = <<_EOF_
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
	<head profile="http://www.w3.org/2005/11/profile">
		<title>Senior Design/Capstone students and projects</title>
		<link rel="stylesheet" href="/a.css" type="text/css" />
		<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1" />
	</head>

	<body>
		<div id="heading">
			<h1>Computer Science and Computer Engineering Department</h1>
			<h1>Senior Design/Capstone</h1>
		</div>

		<div id="studentsList">
			<h1>Students</h1>
#{students_html}
		</div>

		<div id="projectsList">
			<h1>Projects</h1>
#{projects_html}
		</div>
	</body>
</html>
_EOF_

		if @test
			puts "would have written html:", html
			puts "would have written css:", css
		else
			filename = "#{@directory}/index.html"
			File.new(filename, "w+").print html unless @test
			FileUtils.chown('root', 'root', filename)
			FileUtils.chmod(0644, filename)

			filename = "#{@directory}/a.css"
			File.new(filename, "w+").print css unless @test
			FileUtils.chown('root', 'root', filename)
			FileUtils.chmod(0644, filename)
		end
	end

	# ----------------------------------------------------------------------------------------------------

	def makeSdcGroupName(projectDirectoryName)
		"sdc_#{projectDirectoryName}".downcase[0,16]
	end
end

options = OpenStruct.new
options.help = false
options.csvFilename = false
options.directory = false
options.test = false

op = OptionParser.new do |op|
	op.banner = "Usage: #{__FILE__} [options]"
	op.separator("")
	op.separator("Options:")

	op.on_tail("-h", "--help") do
		options.help = true
	end

	op.on("-c", "--csv-file CSVFILE", "Specify backup file") do |csvFilename|
		options.csvFilename = csvFilename
	end

	op.on("-d", "--directory DIRECTORY", "Specify base directory (SDC web root)") do |directory|
		options.directory = directory
	end

	op.on("-t", "--test", "Test mode. (Don\'t actually create anything.)") do
		options.test = true
	end

	options
end

if ARGV.size == 0
	puts op
else
	begin
		op.parse!(ARGV)

		if options.help
			puts op
			exit 0
		end

		raise ArgumentError, "no CSV file specified" unless options.csvFilename
		raise ArgumentError, "no directory specified" unless options.directory

		SdcWebSiteMaker.new(options.csvFilename, options.directory, options.test).make
#	rescue => e
#		puts "error: #{e}"
#		exit 1
	end
end
