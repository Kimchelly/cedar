package cost

import (
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/evergreen-ci/sink/amazon"
	"github.com/evergreen-ci/sink/model"
	"github.com/mongodb/grip"
	"github.com/stretchr/testify/suite"
)

const layout = "2006-01-02T15:04" //Using reference Mon Jan 2 15:04:05 -0700 MST 2006

func init() {
	grip.SetName("sink.cost.test")
}

func getDirectoryOfFile() string {
	_, file, _, _ := runtime.Caller(1)

	return filepath.Dir(file)
}

// CommandsSuite provide a group of tests for the cost helper functions.
type CostSuite struct {
	suite.Suite
	config *model.CostConfig
}

func TestServiceCacheSuite(t *testing.T) {
	suite.Run(t, new(CostSuite))
}

func (c *CostSuite) SetupTest() {
	c.config = &model.CostConfig{}
}

func (c *CostSuite) TestGetDuration() {
	c.config.Opts.Duration = ""
	duration, err := c.config.GetDuration(0) //zero Duration
	c.NoError(err)
	c.Equal(duration.String(), "1h0m0s")
	c.config.Opts.Duration = "12h"
	duration, err = c.config.GetDuration(0)
	c.NoError(err)
	c.Equal(duration.String(), "12h0m0s")
}

func (c *CostSuite) TestGetTimes() {
	start, err := time.Parse(layout, "2017-05-26T12:00")
	c.NoError(err)
	duration := 4 * time.Hour
	endTime := start.Add(duration)
	times := getTimes(start, duration)
	c.Equal(times.start, start)
	c.Equal(times.end, endTime)
}

func (c *CostSuite) TestYAMLToConfig() {
	file := filepath.Join(getDirectoryOfFile(), "testdata", "spend_test.yml")
	config, err := model.LoadCostConfig(file)

	c.NoError(err)
	c.NotNil(config)
	c.Len(config.Providers, 1)
	c.Equal(config.Opts.Duration, "4h")
	c.Equal(config.Providers[0].Name, "fakecompany")
	c.Equal(config.Providers[0].Cost, float32(50000))
	file = "not_real.yaml"
	_, err = model.LoadCostConfig(file)
	c.Error(err)
}

func (c *CostSuite) TestCreateCostItemFromAmazonItems() {
	key := amazon.ItemKey{
		ItemType: "reserved",
		Name:     "c3.4xlarge",
	}
	item1 := &amazon.Item{
		Launched:   true,
		Terminated: false,
		FixedPrice: 120.0,
		Price:      12.42,
		Uptime:     3.0,
		Count:      5,
	}
	item2 := &amazon.Item{
		Launched:   false,
		Terminated: true,
		FixedPrice: 35.0,
		Price:      0.33,
		Uptime:     1.00,
		Count:      2,
	}
	item3 := &amazon.Item{
		Launched:   true,
		Terminated: false,
		FixedPrice: 49.0,
		Price:      0.5,
		Uptime:     1.00,
		Count:      1,
	}
	items := []*amazon.Item{item1, item2, item3}
	item := createCostItemFromAmazonItems(key, items)
	c.Equal(item.Name, key.Name)
	c.Equal(item.ItemType, string(key.ItemType))
	c.Equal(item.AvgPrice, float32(4.42))
	c.Equal(item.FixedPrice, float32(68))
	c.Equal(item.AvgUptime, float32(1.67))
	c.Equal(item.Launched, 6)
	c.Equal(item.Terminated, 2)
}

func (c *CostSuite) TestPrint() {
	report := model.CostReportMetadata{
		Begin:     time.Now().Add(-2 * time.Hour),
		End:       time.Now().Add(-time.Hour),
		Generated: time.Now(),
	}
	output := &model.CostReport{Report: report}
	config := &model.CostConfig{}
	filepath := ""
	c.NoError(WriteToFile(config, output, filepath))
}